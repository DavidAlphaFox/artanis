;;  -*-  indent-tabs-mode:nil; coding: utf-8 -*-
;;  Copyright (C) 2014,2015,2016,2017,2018
;;      "Mu Lei" known as "NalaGinrut" <NalaGinrut@gmail.com>
;;  Artanis is free software: you can redistribute it and/or modify
;;  it under the terms of the GNU General Public License and GNU
;;  Lesser General Public License published by the Free Software
;;  Foundation, either version 3 of the License, or (at your option)
;;  any later version.

;;  Artanis is distributed in the hope that it will be useful,
;;  but WITHOUT ANY WARRANTY; without even the implied warranty of
;;  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;  GNU General Public License and GNU Lesser General Public License
;;  for more details.

;;  You should have received a copy of the GNU General Public License
;;  and GNU Lesser General Public License along with this program.
;;  If not, see <http://www.gnu.org/licenses/>.

;; -----------------------------------------------------------------------
;; This module implemented option-handler-table which is used to deal with
;; flexible rule options.

(define-module (artanis oht)
  #:use-module (artanis utils)
  #:use-module (artanis config)
  #:use-module (artanis sql-mapping)
  #:use-module (artanis db)
  #:use-module (artanis cookie)
  #:use-module (artanis session)
  #:use-module (artanis cache)
  #:use-module (artanis route)
  #:use-module (artanis env)
  #:use-module (artanis mime)
  #:use-module (artanis upload)
  #:use-module (artanis websocket)
  #:use-module (artanis third-party json)
  #:use-module (artanis third-party csv)
  #:use-module (artanis server scheduler)
  #:use-module (artanis irregex)
  #:use-module (artanis lpc)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-26)
  #:use-module (web uri)
  #:use-module (web request)
  #:export (define-handler

             get
             post
             put
             patch
             page-delete

             :sql-mapping
             :str
             :conn
             :raw-sql
             :cookies
             :cache
             :cookies-set!
             :cookies-ref
             :cookies-update!
             :cookies-remove!
             :cookies-setattr!
             :mime
             :auth
             :session
             :from-post
             :websocket
             :lpc))

(define (define-handler method raw-rule opts-and-handler)
  (let* ((rule (string-trim-right raw-rule #\/))
         (keys (rule->keys rule))
         (path-regexp (compile-rule rule))
         (opts (oah->opts opts-and-handler))
         (handler (oah->handler opts-and-handler)))
    (hash-set! *handlers-table*
               (cons method path-regexp)
               (make-handler-rc handler keys (new-oht opts #:rule rule #:keys keys)))))

(define (get rule . opts-and-handler) (define-handler 'GET rule opts-and-handler))
(define (post rule . opts-and-handler) (define-handler 'POST rule opts-and-handler))
(define (put rule . opts-and-handler) (define-handler 'PUT rule opts-and-handler))
(define (patch rule . opts-and-handler) (define-handler 'PATCH rule opts-and-handler))
;; NOTE: delete method is rarely used, and this name will override the list deletion in Scheme.
;;       So my vote is changing its name, feel free to let me know if it's improper.
(define (page-delete rule . opts-and-handler) (define-handler 'DELETE rule opts-and-handler))

;; NOTE: we banned "\" in the path to avoid SQL-injection!!!
(define *rule-regexp* (string->irregex ":[^\\/]+"))
(define *path-keys-regexp* (string->irregex ":([^\\/\\.]+)"))

(define (compile-rule rule)
  (string-append "^"
                 (irregex-replace/all *rule-regexp* rule "([^\\/\\?]+)")
                 "$"))

;; parse rule-string and generate the regexp to parse keys from path-string
(define (rule->keys rule)
  (map (lambda (m) (irregex-match-substring m 1))
       (artanis-list-matches *path-keys-regexp* rule)))

(define-syntax-rule (get-oht rc)
  (handler-rc-oht (get-handler-rc (rc-rhk rc))))

;; NOTE:
;; Returns `values' proc if there's no such keyword was specified.
;; Because we need to support the hooks, so there'd be a proc to receive
;; multi-args when there's no such short-cut.
(define-syntax-rule (=> opt rc args ...)
  (let* ((oht (get-oht rc))
         (h (and oht (hash-ref oht opt))))
    (if h (h rc args ...) values)))

(define-syntax-rule (auth-enabled? rc)
  (hash-ref (get-oht rc) #:auth))
;; --------------------------------------------------------------
;; oht handlers

;; for #:str
(define (str-maker fmt rule keys)
  (let ((tpl (make-db-string-template fmt)))
    (lambda (rc . kargs)
      (and tpl (apply tpl `(,@(alist->kblist (rc-bt rc)) ,@kargs))))))

;; returns a queried conn, users have to get result by themselves.
;; for #:conn
(define (conn-maker yes? rule keys)
  (and yes?
       (case-lambda
         ((rc) (DB-open rc))
         ((rc sql)
          (let ((conn (DB-open rc)))
            (DB-query conn sql)
            conn)))))

(define (raw-sql-maker sql rule keys)
  (lambda (rc mode)
    (let ((r (DB-query (DB-open rc) sql)))
      (match mode
        ('all (DB-get-all-rows r))
        ('top (DB-get-top-row r))
        ((? positive? n) (DB-get-n-rows r n))
        (else (throw 'artanis-err 500 raw-sql-maker
                     "Invalid mode `~a'!" mode))))))

;; for #:cache
(define (cache-maker pattern rule keys)
  (define (non-cache rc body) body)
  (define-syntax-rule (try-public rc) (if (auth-enabled? rc) 'private 'public))
  (match pattern
    ;; disable cache explicitly, sometimes users want to make sure there's no any cache.
    ((#f) non-cache)
    (('static maxage0 ...)
     (lambda* (rc #:key (dir #f) (maxage (->maxage maxage0)))
       (let ((filename (if dir
                           (format #f "~a/~a" dir (rc-path rc))
                           (static-filename (rc-path rc)))))
         (try-to-cache-static-file rc (static-filename (rc-path rc))
                                   (try-public rc) maxage))))
    (((? string? file) maxage0 ...)
     (lambda* (rc #:key (maxage (->maxage maxage0)))
       (try-to-cache-static-file rc file (try-public rc) maxage)))
    (('public (? string? file) maxage0 ...)
     (lambda* (rc #:key (maxage (->maxage maxage0)))
       (try-to-cache-static-file rc file (try-public rc) maxage)))
    (('private (? string? file) maxage0 ...)
     (lambda* (rc #:key (maxage (->maxage maxage0)))
       (try-to-cache-static-file rc file 'private maxage)))
    ((or (? boolean? opts) (? list? opts))
     (lambda (rc body) (try-to-cache-body rc body opts)))
    (else (throw 'artanis-err 500 cache-maker
                 "Invalid pattern!" pattern))))

;; for #:cookies
;; NOTE: Support cookies customization, which let users define special cookies.
;;       Like crypto cookies.
(define (cookies-maker mode rule keys)
  (define *the-remove-expires* "Thu, 01-Jan-70 00:00:01 GMT")
  (define %cookie-set! cookie-set!)
  (define %cookie-ref cookie-ref)
  (define %cookie-modify cookie-modify)
  (define %new-cookie new-cookie)
  (define ckl '())
  (define (cget ck)
    (or (assoc-ref ckl ck)
        (throw 'artansi-err 500 cget "Undefined cookie name" ck)))
  (define (cset! ck k v)
    (and=> (cget ck) (cut %cookie-set! <> k v)))
  (define (cref ck k)
    (and=> (cget ck) (cut %cookie-ref <> k)))
  (define (update rc)
    (rc-set-cookie! rc (map cdr ckl)))
  (define (setattr ck . kargs)
    (apply %cookie-modify (cget ck) kargs))
  (define (remove rc k)
    (let ((cookies (rc-set-cookie rc)))
      (rc-set-cookie!
       rc
       `(,@cookies ,(%new-cookie #:npv '((key "")) #:expires *the-remove-expires*)))))
  (define-syntax-rule (init-cookies names)
    (for-each
     (lambda (ck)
       (set! ckl (cons (cons ck (new-cookie)) ckl)))
     names))
  (match mode
    (('names names ...) (init-cookies names))
    (('custom (names ...) maker setter getter modifier)
     (set! %new-cookie maker)
     (set! %cookie-set! setter)
     (set! %cookie-ref getter)
     (set! %cookie-modify modifier)
     (init-cookies names))
    (else (throw 'artansi-err 500 cookies-maker
                 "Invalid mode while init!" mode)))
  (lambda (rc op)
    (case op
      ((set) cset!)
      ((ref) cref)
      ((setattr) setattr)
      ((update) update)
      ((remove) remove)
      (else (throw 'artanis-err 500 cookies-maker
                   "Invalid operation!" op)))))

;; for #:mime
(define (mime-maker type rule keys)
  (define headers `((content-type . (,(mime-guess type)))))
  (define-syntax-rule (-> func the-args) (values (apply func the-args) #:pre-headers headers))
  (define gen-mime
    (case type
      ((json jsonp) (lambda (args) (-> ->json-string args)))
      ((xml) (lambda (args) (-> sxml->xml-string args)))
      ((csv) (lambda (args) (-> sxml->csv-string args)))
      ((sxml) (lambda (args) (-> object->string args)))
      (else (throw 'artanis-err 500 mime-maker "Invalid type: ~a!" type))))
  (lambda (rc . args) (gen-mime args)))

;; for #:session
(define (session-maker mode rule keys)
  (define* (%spawn rc #:key (idname "sid") (proc session-spawn)
                   path domain expires secure http-only)
    (call-with-values
        (lambda () (proc rc))
      (lambda (sid session)
        (let ((cookie (new-cookie #:npv `((,idname . ,sid))
                                  #:path "/")))
          (and cookie (rc-set-cookie! rc (list cookie)))
          sid))))
  (define spawn-handler
    (match mode
      ((or #t 'spawn) %spawn)
      (`(spawn ,sid)
       (lambda* (rc #:key (path "/") domain (expires 3600) secure (http-only #t))
         (%spawn rc #:idname sid #:path path #:domain domain
                 #:expires expires #:secure secure #:http-only http-only)))
      (`(spawn ,sid ,proc)
       (lambda* (rc #:key (path "/") domain (expires 3600) secure (http-only #t))
         (%spawn rc #:idname sid #:proc proc #:path path #:domain domain
                 #:expires expires #:secure secure #:http-only http-only)))
      (else (throw 'artanis-err 500 session-maker "Invalid config mode: ~a" mode))))
  (define (check-it rc idname)
    (let ((sid (any (lambda (c) (and=> (cookie-ref c idname) car)) (rc-cookie rc))))
      (and=> (pk "session restore"(session-restore (or sid "")))
             (lambda (s) (session-from-correct-client? s rc)))))
  (lambda (rc cmd)
    (match cmd
      ('check (check-it rc "sid"))
      (`(check ,sid) (check-it rc sid))
      ('check-and-spawn
       (or (check-it rc "sid") (spawn-handler rc)))
      (`(check-and-spawn ,sid)
       (or (check-it rc sid) (spawn-handler rc)))
      ('spawn (spawn-handler rc))
      (else (throw 'artanis-err 500 session-maker "Invalid call cmd: ~a" cmd)))))

;; for #:from-post
(define (from-post-maker mode rule keys)
  (define* (post->qstr-table rc #:optional (safe? #f))
    (if (rc-body rc)
        (generate-kv-from-post-qstr (rc-body rc) #:no-evil? safe?)
        '()))
  (define (default-success-ret size-list filename-list)
    (call-with-output-string
      (lambda (port)
        (for-each (lambda (s f)
                    (format port "<p>Upload succeeded! ~a: ~a bytes!</p>" s f))
                  size-list filename-list))))
  (define (default-no-file-ret) "<p>No uploaded files!</p>")
  (define* (store-the-bv rc #:key (uid 33) (gid 33) (path (get-conf '(upload path)))
                         (mode #o664) (path-mode #o775) (sync #f) (simple-ret? #t)
                         (need-mfd? #f)
                         ;; NOTE: One may use these two things for returning
                         ;;       customized result, like JSON or XML.
                         (success-ret default-success-ret)
                         (no-file-ret "No uploaded files!"))
    (match (store-uploaded-files rc #:path path #:sync sync #:simple-ret? simple-ret?
                                 #:mode mode #:uid uid #:gid gid #:path-mode path-mode
                                 #:need-mfd? need-mfd?)
      ('success 'success)
      ((? is-mfds? mfds) mfds)
      (`(success ,slist ,flist) (success-ret slist flist))
      (`(success ,mfds ,slist ,flist) (success-ret mfds slist flist))
      ('none (no-file-ret))
      (else
       (throw 'artanis-err 500 store-the-bv
              "Impossible status! please report bug!"))))
  (define (post-ref plst key) (and=> (assoc-ref plst key) car))
  (define (return-json-mapping j)
    (let ((jt (if (bytevector? j)
                  (json-string->scm (utf8->string j))
                  (throw 'artanis-err 400 return-json-mapping
                         "Invalid body type ~a~%" (detect-type-name j)))))
      (lambda (k)
        (hash-ref jt k))))
  (define (post-handler rc)
    (match mode
      ((or #t 'query-string 'qstr) (post->qstr-table rc))
      ('json (return-json-mapping (rc-body rc)))
      ('qstr-safe (post->qstr-table rc 'safe))
      ((or 'bv 'bytevector) (rc-body rc))
      ;; Get mfds and handle it by yourself
      ;; You may rename the uploaded files, get the key-value from the body
      ;; or anything you want from mfd.
      (('get-mfds-op rest ...)
       (apply get-mfds-op-from-post rc rest))
      ;; upload operation, indeed
      (('store rest ...)
       (handle-upload (lambda () (apply store-the-bv rc rest))))
      (else (throw 'artanis-err 500 post-handler "Invalid mode `~a'!" mode))))
  (define (get-values-from-post pl . keys)
    (apply
     values
     (map
      (lambda (k) (post-ref pl k))
      keys)))
  (lambda (rc . cmd)
    (match cmd
      (`(get ,key) (post-ref (post-handler rc) key))
      ('(get) (post-handler rc))
      (('get-vals keys ...) (apply get-values-from-post (post-handler rc) keys))
      ('(store) (post-handler rc))
      ('(get-mfds-op) (post-handler rc))
      (else (throw 'artanis-err 500 from-post-maker "Invalid cmd `~a'!" cmd)))))

;; for #:websocket
;;
(define (websocket-maker mode rule keys)
  (match mode
    ('send-only
     ;; NOTE: send-only is used for sending messages to registed websocket connection by
     ;;       the specified pipe name. If you use this option, then the rule will not init
     ;;       a websocket handshake. It's just for sending messages.
     ;; NOTE; If you use this option, you can only send messages, but other can't send
     ;;       message to you. That is to say, it's one-way transimission.
     ;; NOTE: Other options could be bi-direction transmission without specified 'send/recv
     ;;       explicitly.
     (DEBUG "~a is registered to be named-pipe send only rule!" rule))
    (((or #t 'raw))
     (this-rule-enabled-websocket! rule 'raw))
    (('proto (? symbol? proto))
     ;; TODO: call protocol initilizer, and establish websocket for it.
     ;; NOTE: In Artanis, we accept only one protocol for each URL-remapping,
     ;;       if you have several protocols to service, please use different
     ;;       URL-remapping.
     (this-rule-enabled-websocket! rule proto))
    (('redirect (? string? ip/usk))
     ;; NOTE: We use IP rather than hostname, since it's usually redirected to
     ;;       a LAN address. Using hostname may cause DNS issues.
     ;; NOTE: ip/usk means ip or unix-socket, the pattern should be this:
     ;;       ^ip://(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(:[0-9]{1,5})?$
     ;;       ^unix://[a-zA-Z-_0-9]+\\.socket$
     ;; NOTE: Equivalent to transparent proxy.
     ;; TODO: call protocol initilizer, and establish websocket
     ;;       to redirect it.
     ;; NOTE: Just call :websocket as the handler is enough to redirect data automatically
     (this-rule-enabled-websocket! rule 'redirect))
    (('proxy (? symbol? proto))
     ;; NOTE: Setup a proxy with certain protocol handler.
     ;;       Different from the regular proxy design, the proxy in Artanis doesn't
     ;;       need a listen port, since it's always 80/443. The client should
     ;;       support websocket, and visit the related URL for establishing
     ;;       a websocket channel. Then the rest is the same with regular proxy.
     (this-rule-enabled-websocket! rule 'proxy))
    (else (throw 'artanis-err 500 websocket-maker "Invalid type `~a'!" mode)))
  (lambda (rc . cmd)
    (match cmd
      ('(payload) (websocket-frame-payload (rc-body rc)))
      ('(frame) (rc-body rc))
      (`(send ,name ,data) (send-to-websocket-named-pipe name data))
      (else (throw 'artanis-err 500 websocket-maker "Invalid cmd `~a'!" cmd)))))

;; for #:lpc
;; Local Persistent Cache
(define (lpc-maker mode rule keys)
  (define (gen-lpc-handler rc cmd)
    (let ((lpc (rc-lpc rc)))
      (match cmd
        (`(set ,key ,val) (lpc-set! lpc key val))
        (((or 'ref 'get) key) (lpc-ref lpc key))
        (else (throw 'artanis-err 500 gen-lpc-handler "Invalid cmd `~a'!" cmd)))))
  (match mode
    (#t
     (lambda (rc . cmd)
       (when (not (rc-lpc rc))
         (let ((lpc (or (get-lpc-instance!) ((new-lpc)))))
           (rc-lpc! rc lpc)))
       (gen-lpc-handler rc cmd)))
    ((backend . args)
     (lambda (rc . cmd)
       (when (not (rc-lpc rc))
         (let ((lpc (or (get-lpc-instance!)
                        (apply (new-lpc #:backend backend) args))))
           (rc-lpc! rc lpc)))
       (gen-lpc-handler rc cmd)))
    (else (throw 'artanis-err 500 lpc-maker "Invalid pattern `~a'!" mode))))

;; ---------------------------------------------------------------------------------

;; NOTE: these short-cut-maker should never be exported!
;; ((handler arg rule keys) rc . args)
;; NOTE: If the keyword wasn't specified while defining the url-remap,
;;       the handler should return #f.
;; CONVENTION:
;; 1. When a var is arounded with ${..}, and there's ":" as its prefix,
;;    say, ${:xxx}, it means "to get xxx from rule key".
;; 2. Arounded with ${..}, and there's "@" as its prefix, say, ${@xxx},
;;    it means "to get xxx from body" (POST way).
(define *options-meta-handler-table*
  `(;; a short way for sql-mapping from the bindings in rule
    ;; e.g #:sql-mapping "select * from table where id=${:id}"
    (#:sql-mapping . ,sql-mapping-maker)

    ;; generate a string from the bindings in rule
    ;; e.g (get "/get/:who" #:str "hello ${:who}" ...)
    (#:str . ,str-maker)

    ;; short-cut for authentication
    ;; #:auth accepts these values:
    ;; 1. SQL as string template.
    ;; 2. (table-name username-field passwd-field crypto-proc)
    ;; 3. (table-name crypto-proc), so passwd field will be "passwd" in default.
    ;; e.g (get "/auth"
    ;;      #:auth "select ${passwd} from blog where usrname=${myname}"
    ;;      (lambda (rc)
    ;;       (:auth rc #:usrname (params rc "username") #:passwd (params rc "passwd"))
    ;;       ...))
    ;; The #:usrname and #:passwd will be expaned automatically.
    ;; or (get "/auth" #:auth `(blog "myuser" "mypasswd" ,string->md5)
    ;;     (lambda (rc)
    ;;      (if (:auth rc)
    ;;          (redirect-to rc "/dashboard")
    ;;          (redirect-to rc "/login?auth_failed=true"))))
    ;; or (get "/auth" #:auth `(blog ,string->md5)
    ;;     (lambda (rc)
    ;;      (if (:auth rc)
    ;;          (redirect-to rc "/dashboard")
    ;;          (redirect-to rc "/login?auth_failed=true"))))
    (#:auth . ,auth-maker)

    ;; Auto connection
    ;; request a connection from connection-pool, and close automatically.
    ;; NOTE: if you use #:sql-mapping short-cut, there's already a connect picked
    ;;       from pool, so #:sql-mapping implies #:conn is set to #t.
    ;; TODO: add recycling step after rule handler returning.
    ;; e.g (get "/show-all" #:conn #t
    ;;      (lambda (rc)
    ;;       (:conn rc "select * from articles")))
    (#:conn . ,conn-maker)

    ;; Raw simple sql query
    ;; NOTE: Raw sql is a const string of valid SQL.
    ;; E.g: (get "/sqltest"
    ;;       #:raw-sql "select * from Persons where name='nala'"
    ;;       (lambda (rc)
    ;;        (:raw-sql rc 'all)))
    ;; It's used for a quick query, but you can't modify/specify query on the fly.
    ;; Usage:
    ;;  :raw-sql procedure accepts three modes:
    ;; 1. 'all for getting all results.
    ;; 2. certain number n for getting top n results.
    ;; 3. 'top for getting the top result.
    (#:raw-sql . ,raw-sql-maker)

    ;; Web caching
    ;; The default value is #f.
    ;; This is useful for web caching.
    ;; values:
    ;; * #t: will store the md5 of this page content,
    ;;       and compare it with Etag.
    ;; * #f: won't store md5, and won't do any caching work.
    ;;       Etag would be ignored. If the current rule is for dynamic page,
    ;;       you have to set it to #f.
    ;; * filename: You may use (cache-file rc) to return the static file,
    ;;             it's the same function like emit-response-with-file.
    ;;             The difference is to cache it in memory.
    ;; * Caveats:
    ;; 1. #t will generate the dynamic page and get md5 for it anyway, the
    ;;    only advantage would be saving the bandwidth (return 304).
    ;; 2. Whether to use #:cache is depending on you.
    ;; NOTE: this option will be disabled automatically for some reasons:
    ;; 1. when #:auth was used in the same rule.
    ;; 2. when there's any HTTP header to stop the caching.
    (#:cache . ,cache-maker)

    ;; short-cut to set cookies
    ;; NOTE: you don't have to use :cookies-update! to sync cookies in rc,
    ;;       there's a hook for that before response.
    ;; e.g (get "/" #:cookies '(ca cb)
    ;;      (lambda (rc)
    ;;       (:cookies-set! rc 'ca "sid" "1231231")
    ;;       "ok"))
    (#:cookies . ,cookies-maker)

    ;; Convert to certain MIME type
    ;; There're three types: json/csv/xml/sxml
    ;; NOTE: Only used at the end of the handler (to replace response-emit)
    ;; e.g (get "/json" #:mime 'json
    ;;       (lambda (rc)
    ;;         (let ((j (json (object ("name" "nala") ("age" "15")))))
    ;;           (:mime j))))
    ;; e.g (get "/csv" #:mime 'csv
    ;;       (lambda (rc)
    ;;         (:mime '((a 1) (b 2)))))
    ;; ==> "a,1\nb,2\n"
    ;; e.g (get "/xml" #:mime 'xml
    ;;       (lambda (rc)
    ;;         (:mime '((a 1) (b 2)))))
    ;; ==> "<a>1</a><b>2</b>"
    ;; e.g (get "/sxml" #:mime 'sxml
    ;;       (lambda (rc)
    ;;         (:mime '((a 1) (b 2)))))
    ;; ==> "((a 1) (b 2))"
    (#:mime . ,mime-maker)

    ;; Spawn sessions
    (#:session . ,session-maker)

    ;; Get data from POST
    (#:from-post . ,from-post-maker)

    ;; Establish websocket channel
    ;; Each time developers set :websocket and specifed a protocol, say, `myproto',
    ;; Artanis will check if the file app/protocols/myproto.scm exists, then load
    ;; the protocol initialize function in `myproto' which will also add `myproto'
    ;; into *proto-table*. Then ragnarok will take charge of it to call the correct
    ;; handlers.
    ;; There're 3 cases:
    ;; 1. Regular protocol handling over websocket
    ;;    The initializer will create an instance for the protocol.
    ;; 2. Redirect to another address (IP or UNIX socket)
    ;;    The initializer will create a binding pair in redirect table:
    ;;    src port and des port.
    ;;    In this case, there's no protocol handling in Artanis. The protocol handler
    ;;    is in remote (could be a host machine, or a process in current OS).
    ;; 3. Proxy mode:
    ;;    Different from reguar proxy, the proxy in Artanis runs over websocket, and
    ;;    there's no extra listenning port, only 80/443.
    ;;    In this case, there're 2 situations:
    ;;    a. transparent proxy
    ;;       No protocol handling at all, just redirecting the data without cooking.
    ;;    b. cooked proxy
    ;;       There's a bound protocol instance for it.
    (#:websocket . ,websocket-maker)

    ;; Apply an instance of Local Persistent Cache
    ;; This is useful when you want to store some key-value stuffs.
    ;; There're 2 cases:
    ;; 1. #t
    ;;    Initialize lpc with default configuration, the backend is Redis, write-able.
    ;; 2. (backend . args)
    ;;    Specify the avalailable backend, and the args as the configuare options.
    (#:lpc . ,lpc-maker)))

(define-macro (meta-handler-register what)
  `(define-syntax-rule (,(symbol-append ': what) rc args ...)
     (=> ,(symbol->keyword what) rc args ...)))

;; register all the meta handler
(meta-handler-register sql-mapping)
(meta-handler-register str)
(meta-handler-register conn)
(meta-handler-register raw-sql)
(meta-handler-register cookies)
(meta-handler-register cache)
(meta-handler-register mime)
(meta-handler-register cookies)
(meta-handler-register auth)
(meta-handler-register session)
(meta-handler-register from-post)
(meta-handler-register websocket)
(meta-handler-register lpc)

(define-syntax-rule (:cookies-set! rc ck k v)
  ((:cookies rc 'set) ck k v))
(define-syntax-rule (:cookies-ref rc ck k)
  ((:cookies rc 'ref) ck k))
(define-syntax-rule (:cookies-setattr! rc ck kargs ...)
  ((:cookies rc 'setattr) ck kargs ...))
(define-syntax-rule (:cookies-update! rc)
  ((:cookies rc 'update) rc))
(run-before-response! (lambda (rc body) (:cookies-update! rc)))
(define-syntax-rule (:cookies-remove! rc k)
  ((:cookies rc 'remove) k))

(define-syntax-rule (oh-ref o)
  (assq-ref *options-meta-handler-table* o))

;; return #f when there's no opt specified
(define* (new-oht opts #:key (rule 'no-rules) (keys 'no-keys))
  (match opts
    ((() ()) #f)
    (else
     (let ((oht (make-hash-table)))
       (apply
        for-each
        (lambda (k v)
          (let ((h (oh-ref k)))
            (cond
             ((or h (eq? k #:handler))
              ;; #:handler is user customed handler
              (hash-set! oht k (h v rule keys)))
             (else #f))))
        opts)
       oht))))
