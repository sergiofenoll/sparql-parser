(in-package :delta-messenger)

;;;; Delta messenger
;;;;
;;;; We started modelling this as a class based system because we
;;;; thought some flexibility would be nice.  Whilst writing this we
;;;; realized this is likely a non-feature.  The code written here does
;;;; not actively help in making this more configurable through
;;;; environment variables and a direct implementation would likely be
;;;; cleaner.

(defparameter *delta-handlers* nil
  "Handlers for the delta messages.")

(defclass delta-handler () ()
  (:documentation "Superclass of all delta handlers."))

(defclass delta-logging-handler (delta-handler) ()
  (:documentation "Logs deltaa messages to standard output."))

(defclass delta-remote-handler (delta-handler)
  ((endpoint :initarg :endpoint :initform (error "Must supply target for delta post handler."))
   (method :initarg :method :initform :post))
  (:documentation "Sends a  delta post to the given endpoint."))

(defgeneric handle-delta (handler &key inserts deletes)
  (:documentation "Handles a delta message for the raw insert and delete quads.  This may include sending it out to an external provider.")
  (:method ((handler delta-logging-handler) &key inserts deletes)
    (format t "~&Notify others on quads having been written:~% Inserted Quads: ~{~%  ~A~}~% Deleted Quads: ~{~%  ~A~}~%"
            (mapcar (alexandria:compose #'jsown:to-json #'quad-to-jsown-binding) inserts)
            (mapcar (alexandria:compose #'jsown:to-json #'quad-to-jsown-binding) deletes)))
  (:method ((handler delta-remote-handler) &key inserts deletes)
    (when (or inserts deletes)
      ;; TODO: share following headers for this request with the new request
      ;;   - mu-auth-allowed-groups
      ;;   - mu-auth-sudo (or make that influence mu-auth-allowed-groups?)
      ;;   - mu-session-id
      ;;   - mu-call-id (does this need to be shadowed here?)
      (with-slots (endpoint method) handler
        (let ((delta-message
                (jsown:to-json
                 (jsown:new-js
                   ("changeSets"
                    (list
                     (delta-to-jsown :insert inserts
                                     :delete deletes
                                     :scope (connection-globals:mu-call-scope))))))))
          (dex:request endpoint
                       :method method
                       :headers `(("content-type" . "application/json")
                                  ("mu-call-id-trail" . ,(jsown:to-json (list (connection-globals:mu-call-id)))) ; TODO: append to earlier call-id-trail
                                  ("mu-call-id" . ,(random 1000000000))
                                  ("mu-session-id" . ,(connection-globals:mu-session-id)))
                       :content delta-message))))))

(defun quad-to-jsown-binding (quad)
  "Converts QUAD to a jsown binding."
  (jsown:new-js
    ("subject" (handle-update-unit::match-as-binding (getf quad :subject)))
    ("predicate" (handle-update-unit::match-as-binding (getf quad :predicate)))
    ("object" (handle-update-unit::match-as-binding (getf quad :object)))))

(defun delta-to-jsown (&key insert delete scope)
  "Convert delta inserts and deletes message to jsown body for inserts and deletes."
  (let ((delta
          (jsown:new-js
            ("insert" (mapcar #'quad-to-jsown-binding insert))
            ("delete" (mapcar #'quad-to-jsown-binding delete)))))
    (when (and scope (not (eq scope acl:_)))
      (setf (jsown:val delta "scope") scope))
    delta))

(defun delta-notify (&key inserts deletes)
  "Entrypoint of the delta messenger.  Dispatches messages to all relevant places."
  (mapcar (alexandria:rcurry #'handle-delta :inserts inserts :deletes deletes)
          *delta-handlers*))

(defun add-delta-messenger (target &key (method :post))
  "Adds a new delta messenger to the list of targets."
  (push (make-instance 'delta-remote-handler :endpoint target :method method)
        *delta-handlers*))

;; (push (make-instance 'delta-logging-handler) *delta-handlers*)
;; (add-delta-messenger "http://localhost:8089")
