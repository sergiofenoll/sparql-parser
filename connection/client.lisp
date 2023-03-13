(in-package #:client)

(defparameter *backend* "http://localhost:8890/sparql")
(defparameter *log-sparql-query-roundtrip* nil)

(defun query (string)
  "Sends a query to the backend and responds with the response body."
  (multiple-value-bind (body code headers)
      (let ((uri (quri:uri *backend*)))
        (setf (quri:uri-query-params uri)
              `(("query" . ,string)))
        (dex:request uri
                     :method :get
                     :use-connection-pool t
                     :keep-alive t
                     :force-string t
                     ;; :verbose t
                     :headers `(("accept" . "application/sparql-results+json")
                                ("mu-call-id" . ,(mu-call-id))
                                ("mu-session-id" . ,(mu-session-id)))))
    (declare (ignore code headers))
    (when *log-sparql-query-roundtrip*
      (format t "~&Requested:~%~A~%and received~%~A~%"
              string body))
    body))

(defun bindings (query-result)
  "Converts the string representation of the SPARQL query result into a set
of JSOWN compatible BINDINGS."
  (jsown:filter (jsown:parse query-result)
                "results" "bindings"))

(defun batch-map-solutions-for-select-query* (query &key for batch-size usage)
  (declare (ignore for batch-size))
  (sparql-parser:with-sparql-ast query
    (let* ((altered-query (if usage
                              (acl:apply-access-rights query :usage usage)
                              query))
           (query-string (sparql-generator:write-valid altered-query)))
      (break "Batch mapping ~A" query-string)
      (client:bindings (client:query query-string)))))

(defmacro batch-map-solutions-for-select-query ((query &key for batch-size usage) (bindings) &body body)
  "Executes the given operation in batches.

  FOR can be used to identify a default batch size to be used as well as
  to calculate the batches requested from the server side through
  centralized configuration.

  BATCH-SIZE allows to override the amount of results fetched in one
  batch.

  Executes the query and returns a list of the results for each batch."
  ;; TODO: move this file into a module about query execution.
  `(let ((,bindings (batch-map-solutions-for-select-query* ,query :for ,for :batch-size ,batch-size :usage ,usage)))
     (list ,@body)))

