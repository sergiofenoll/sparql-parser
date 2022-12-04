(in-package #:reasoner-term-info)

;;;; What does a constraint look like?
;;;;
;;;; a full constraint is a hash-table with URI-OR-VAR as the HASH-KEY
;;;; and an `(:or ,@info)
;;;;
;;;; an info block will differ between variables and primitives due to
;;;; their position in the constraint.  we currently only support
;;;; specific values.  limitations from other constraints (for example
;;;; ?foo > 1000) are not supported.
;;;;
;;;; variable
;;;;   :forward-predicates ((uri-or-var . values))
;;;;   :backward-predicates ((uri-or-var . values))
;;;; primitive
;;;;   :backward-predicates ((uri-or-var . values))
;;;;
;;;; these constraints will later be dispatched to the predicates where
;;;; they'll be used for graph reasoning.
;;;;
;;;; a full constraint is a list of these constraints wrapped in an
;;;; `(:or) block.
;;;;
;;;; We represent alterantives (for instance, introduced through UNION)
;;;; but also need to represent an empty union.  As such, there must be
;;;; a difference between not having any constraints, and the
;;;; alternative of having no constraints.
;;;;
;;;; no constraints :: (:or nil)
;;;;
;;;; an option with no constraints and another with a constraint
;;;; (through a union) :: (:or nil ((var-a (:forward-predicates (uri-a
;;;; . nil)))))
;;;;
;;;; when joining constraints we add to the current constraints.  the
;;;; rules for merging constraint limitations:
;;;;
;;;; fixpoint limitation :: nil
;;;;
;;;; merging non-overlapping constraints :: append the constraints
;;;; (union '(:forward-predicates ((uri-a . nil))) '(:forward-predicates
;;;; ((uri-b . nil)))) would result in '(forward-predicates ((uri-a
;;;; . nil) (uri-b . nil)))
;;;;
;;;; merging overlapping constraints :: make a list of any of the
;;;; values, as each of the values must be present.
;;;;
;;;; (union '(:forward-predicates ((uri-a uri-x))) '(:forward-predicates
;;;; ((uri-a uri-y)))) would result in '(:forward-predicates ((uri-a
;;;; uri-x uri-y)))
;;;;
;;;;
;;;; Joining :or constraints
;;;;
;;;; This is the most common case of constraints.  We either join up, or
;;;; we join sideways, but we join nothing.  Joins tend to come from
;;;; multiple angles and it should be distributative (join (join a b) c)
;;;; should be the same as (join a (join b c)).
;;;;
;;;; joining empty matches :: (join (:or nil) (:or nil)) this is the
;;;; fixpoint and hence it must be (:or nil).
;;;;
;;;; joining a constraint with an empty match :: the fixpoint must be
;;;; ignorable, hence it must join to the other value: (join '(:or nil)
;;;; '(:or (uri-a (:forward-predicates ((uri-b . nil)))))) '(:or (uri-a
;;;; (:forward-predicates ((uri-b . nil)))))
;;;;
;;;; joining constraints with multiple alternatives in the :or :: for
;;;; this case the cross product must be made of each :or option, each
;;;; of these can be joined by the aforementioned strategies. (join
;;;; '(:or A B) '(:or C D)) must result in `(:or ,(join A C) ,(join A D)
;;;; ,(join B C) ,(join B D))
;;;;
;;;; simplification :: at any stage we may create multiple clauses that
;;;; express the same information.  any :or constraints that have the
;;;; same content can be folded.

(defparameter *match-term-info* (make-hash-table :test 'eq)
  "Term info options at clause MATCH.

The term info options are collections of constraints that hold at the key MATCH.")

(defmacro with-match-term-info (&body body)
  "Executes code-block with a scoped match-term-info block."
  `(let ((*match-term-info* (make-hash-table :test 'eq)))
     ,@body))

(defun term-info (match &optional (default (list :or (make-hash-table :test 'equal))))
  "Yields known term information at MATCH.

These are options of constraints that we know of at MATCH.  They are
distributed amongst matches."
  (gethash match *match-term-info* default))

(defun (setf term-info) (value match &optional (default (list :or (make-hash-table :test 'equal))))
  "Sets the term-info for VALUE"
  (setf (gethash match *match-term-info* default) value))

(defun ensure-term-info (match)
  "Ensures term-info has a setting for MATCH and returns it."
  (multiple-value-bind (value foundp)
      (term-info match)
    (unless foundp
      (setf (term-info match) value))
    value))

(defun print-term-info (match &optional stream)
  "Prints TERM-INFO for MATCH on STREAM"
  (format stream ":or ~{~A~,^~&~}"
          (mapcar #'alexandria:hash-table-plist (rest (term-info match)))))

(defun add-subject-predicate-object (match subject predicate object &optional (also-set-backward t) (predicate-type :forward-predicates))
  "Adds the SUBJECT PREDICATE OBJECT combination to the known knowledge of MATCH."
  ;; types of predicates:
  ;; - :forward-predicates
  ;; - :backward-predicates
  ;;
  ;; NOTE: the solution with also-set-backward and predicate-type is not
  ;; the cleanest approach.  we could refactor this someday.
  (let ((subject-string (progn match
                               subject
                               (or
                                (sparql-manipulation:match-symbol-case subject ; should also accept t
                                  (ebnf::|ABSTRACT-IRI| (reasoner::cached-expanded-uri subject)))
                                (sparql-generator:write-valid-match subject))))
        (predicate-string (sparql-generator:write-valid-match predicate))
        (object-string (progn match
                              object
                              (or
                               (sparql-manipulation:match-symbol-case object
                                 (ebnf::|ABSTRACT-IRI| (reasoner::cached-expanded-uri object)))
                               (sparql-generator:write-valid-match object)))))
    ;; subject exists with :forward-perdicates
    (unless (assoc predicate-string
                   (getf (gethash subject-string
                                  (second (term-info match)))
                         predicate-type)
                   :test #'primitive-term-equal)
      ;; subject exists but predicate is not known
      (push (list predicate-string)
            (getf (gethash subject-string
                           (second (ensure-term-info match)))
                  predicate-type)))
    ;; we now know the subject-predicate combination exists
    (let ((predicate-cell (assoc predicate-string
                                 (getf (gethash subject-string
                                                (second (term-info match)))
                                       predicate-type)
                                 :test #'primitive-term-equal)))
      (if predicate-cell
          (unless (find object-string (rest predicate-cell) :test #'primitive-term-equal)
            (setf (cdr (last predicate-cell)) (list object-string)))
          (push (list predicate object-string)
                (getf (gethash subject-string
                               (second (ensure-term-info match)))
                      predicate-type))))
    ;; if object represents an iri or a variable, we must set the backward-predicates too
    ;; TODO: support RDFLiteral
    (when also-set-backward
      (sparql-manipulation:match-symbol-case object
        (ebnf::|ABSTRACT-IRI| (add-subject-predicate-object match object predicate subject nil :backward-predicates))
        (ebnf::|ABSTRACT-VAR| (add-subject-predicate-object match object predicate subject nil :backward-predicates))
        (ebnf::|ABSTRACT-PRIMITIVE| nil
               ;; (format t "~&Not defining inverse predicate for primitive ~A~%"
               ;;         object-string)
               )
        (t (warn "Received an unknown type of value in REASONER-TERM-INFO:ADD-SUBJECT-PREDICATE-OBJECT ~A" object))))))

(defun primitive-term-equal (left right)
  "Compares two primitive terms as used by the reasoner."
  ;; this currently assumes a string as a value.  However, these could
  ;; have a different representation in the future instead.  String
  ;; comparison is sufficient for now.
  (string= left right))

(defun join-constraint-primitive-predicates-constraint (left-predicates right-predicates)
  "Joins :forward-predicates or :backward-predicates."
  ;; We know both have the form ((str str str ...) (str) ...)
  (let* ((predicate-groups (group-by (append left-predicates right-predicates)
                                     #'primitive-term-equal
                                     :key #'first)))
    (loop for predicates in predicate-groups
          for key = (caar predicates)
          for objects = (remove-duplicates
                         (loop for (pred . values) in predicates
                               append values)
                         :test #'primitive-term-equal)
          collect (cons key objects))))

(defun join-constraint-primitives (left right)
  "Joins the constraint primitives of two primitves which have the same subject."
  ;; Both have a form like 
  ;; (:forward-predicates ((str str) (str))
  ;;  :backward-predicates ((str) (str str str)))
  (list :forward-predicates
        (join-constraint-primitive-predicates-constraint
         (getf left :forward-predicates)
         (getf right :forward-predicates))
        :backward-predicates
        (join-constraint-primitive-predicates-constraint
         (getf left :backward-predicates)
         (getf right :backward-predicates))))

(defun join-or-constraints-2 (left right)
  "Joins two term constraints."
  ;; Both have a hash-table form like:
  ;;
  ;; { uri-a => (:forward-predicates ((uri-q uri-r))
  ;;             :backward-predicates ((uri-s)))
  ;;   uri-b => (:forward-predicates ((uri-t)))) }
  ;;
  ;; This function searches to combine the solutions of each uri from
  ;; left into right and vice-versa
  (let ((result (make-hash-table :test 'equal)))
    (loop for key in (union (alexandria:hash-table-keys left)
                            (alexandria:hash-table-keys right)
                            :test #'primitive-term-equal)
          for left-value = (gethash key left)
          for right-value = (gethash key right)
          for combined-value = (join-constraint-primitives left-value right-value)
          do
             (setf (gethash key result) combined-value))
    result))

(defun join-or-constraints (left right)
  "Joins two or constraints by creating a data structure which combines the
knowledge of both in a single :or constraint."
  ;; Both have a form like:
  ;; (:or { uri-a => (:forward-predicates ((uri-q uri-r))
  ;;                  :backward-predicates ((uri-s)))
  ;;        uri-b => (:forward-predicates ((uri-t))) }
  ;;      { uri-a => (:forward-predicates ((uri-u))) })
  (let ((left-alternatives (rest left))
        (right-alternatives (rest right)))
    (fold-or-constraint
     `(:or ,@(loop for left-alternative in left-alternatives
                   append (loop for right-alternative in right-alternatives
                                collect (join-or-constraints-2 left-alternative right-alternative)))))))

(defun fold-or-constraint (constraint)
  "Folds an or constraint which may have multiple patterns into the
simplest form that represents the same contsraints."
  ;; TODO: implement constraint folding
  constraint)

(defun union-term-info-for-or-constraints (or-constraints)
  "unions a set of or-constraints, combining them be moving knowledge across."
  (loop for new-constraint in or-constraints
        for constraint = new-constraint
          then (join-or-constraints constraint new-constraint)
        finally (return constraint)))

(defun union-term-info (&rest matches)
  "For each of the matches, ensure the constraints are pushed down into each match."
  ;; If there are multiple alternatives, they should be multiplied

  ;; In order to combine the knowledge, we have to multiply each of the
  ;; constraints.  This may explode.

  ;; TODO: Only pass on relevant knowledge by analyzing the intersting
  ;; bits early on, making this easier to analyze and substantially
  ;; easier to process with multiple UNIONs
  (union-term-info-for-or-constraints
   (mapcar (lambda (match)
             (term-info match (list :or (make-hash-table :test 'equal))))
           matches)))
