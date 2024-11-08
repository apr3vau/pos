;; -*- mode: Lisp; coding: utf-8-unix; -*-
;; Copyright (c) 2024, April & May
;; SPDX-License-Identifier: 0BSD

(in-package aprnlp)

(defclass dep-parser (perceptron-processor)
  ((name :initform "unnamed-dep-arser")))

(defparameter *loaded-dep-parser* nil)

(defparameter *root-word* (make-word :form :root :upos :root :head -1 :id 0))

(defmethod load-processor ((class (eql 'dep-parser)) file)
  #+lispworks (hcl:load-data-file file)
  #-lispworks (load file)
  *loaded-dep-parser*)

(defmethod save-processor ((processor dep-parser) directory)
  (with-slots (name weights) processor
    (let ((filename (make-pathname :name name :type "fasl" :defaults directory)))
      #+lispworks
      (hcl:with-output-to-fasl-file (out filename :overwrite t)
        (hcl:dump-form '(setf *loaded-dep-parser* (make-instance (class-of processor))) out)
        (hcl:dump-form `(setf (slot-value *loaded-dep-parser* 'name) ,name) out)
        (hcl:dump-form `(setf (slot-value *loaded-dep-parser* 'weights)
                              (plist-to-table ',(table-to-plist weights)))
                       out))
      #-lispworks
      (let ((src (make-pathname :name name :type "lisp" :defaults directory)))
        (with-open-file (out src
                             :direction :output
                             :if-exists :supersede
                             :if-does-not-exist :create)
          (prin1 '(setf *loaded-dep-parser* (make-instance (class-of processor))) out)
          (prin1 `(setf (slot-value *loaded-dep-parser* 'name) ,name) out)
          (prin1 `(setf (slot-value *loaded-dep-parser* 'weights)
                        (plist-to-table ',(table-to-plist weights)))
                 out))
        (compile-file src :output-file filename)
        (delete-file src))
      (log-info "Tagger saved to ~A, size: ~A" (namestring filename) (print-size (file-size-in-octets filename)))
      *loaded-dep-parser*)))

(defun dep-features (left-word right-word stack buffer buffer-pointer)
  (let ((right-form   (general-form right-word))
        (left-form    (general-form left-word))
        (right-pos    (word-upos right-word))
        (left-pos     (word-upos left-word))
        (left-suffix  (word-suffix left-word))
        (right-suffix (word-suffix right-word))
        (distance     (if (= (word-id left-word) 0) 0
                        (- (word-id left-word) (word-id right-word)))))
    (vector (list :form     left-form   right-form)
            (list :pos      left-pos    right-pos)
            (list :word-pos left-form   right-pos)
            (list :pos-word left-pos    right-form)
            (list :form     left-form   t)
            (list :form     t           right-form)
            (list :pos      left-pos    t)
            (list :pos      t           right-pos)
            ;(list :form     t           t)
            (list left-pos  right-pos   distance)
            (list :suffix   left-pos    right-suffix)
            (list :suffix   left-suffix right-pos)
            (list :suffix   left-suffix right-suffix)
            
            (list :stack left-form (when (second stack) (word-form (second stack))))
            (list :stack-pos left-pos (when (second stack) (word-upos (second stack))))
            (list :buffer right-form
                  (when (< (1+ buffer-pointer) (length buffer))
                    (word-form (aref buffer (1+ buffer-pointer)))))
            (list :buffer-pos right-pos
                  (when (< (1+ buffer-pointer) (length buffer))
                    (word-upos (aref buffer (1+ buffer-pointer)))))
            )))

(defmethod process ((parser dep-parser) sentence)
  (with-slots (weights) parser
    (let* ((sentence-len (if (array-has-fill-pointer-p sentence)
                             (fill-pointer sentence)
                           (length sentence)))
           (sentence-pointer 0)
           (stack (list *root-word*))
           left right
           (actions (dict #'eq
                          :shift (lambda ()
                                   (push right stack)
                                   (incf sentence-pointer))
                          :reduce (lambda () (pop stack))
                          :left-arc (lambda ()
                                      (setf (word-head left) (word-id right)
                                            stack (cdr stack)))
                          :right-arc (lambda ()
                                       (setf (word-head right) (word-id left)
                                             stack (cons right stack))
                                       (incf sentence-pointer)))))
      (loop
         (when (= sentence-pointer sentence-len)
           (return))
         (setq left (first stack)
               right (aref sentence sentence-pointer))
         (let ((scores (make-hash-table :test #'eq))
               (features (dep-features left right stack sentence sentence-pointer)))
           (iter (for feature :in-vector features)
                 (when-let (table (apply #'href-default nil weights feature))
                   (iter (for (class weight) :in-hashtable table)
                         (incf (gethash class scores 0.0) weight))))
           (let ((action (iter (for (class weight) :in-hashtable scores)
                               (finding class :maximizing weight))))
             (when (= (length stack) 1)
               (if (and (= sentence-pointer (1- sentence-len))
                        (eq action :shift))
                   (setq action :right-arc)
                 (setq action :shift)))
             (when (and (= sentence-pointer (1- sentence-len))
                        (> (length stack) 1)
                        (eq action :shift))
               (setq action :reduce))
             (funcall (gethash action actions)))))
      sentence)))

(defun dep-parser-train-sentence (parser sentence)
  (with-slots (weights) parser
    (let* ((sentence-len (if (array-has-fill-pointer-p sentence)
                             (fill-pointer sentence)
                           (length sentence)))
           (sentence-pointer 0)
           (correct-count 0)
           (total-count 0)
           (stack (list *root-word*))
           left right
           (actions (dict #'eq
                          :shift (lambda ()
                                   (push right stack)
                                   (incf sentence-pointer))
                          :reduce (lambda () (pop stack))
                          :left-arc (lambda ()
                                      (setf (word-head left) (word-id right)
                                            stack (cdr stack)))
                          :right-arc (lambda ()
                                       (setf (word-head right) (word-id left)
                                             stack (cons right stack))
                                       (incf sentence-pointer)))))
      (loop
         (when (= sentence-pointer sentence-len)
           (return))
         (setq left (first stack)
               right (aref sentence sentence-pointer))
         (let ((scores (make-hash-table :test #'eq))
               (features (dep-features left right stack sentence sentence-pointer)))
           (iter (for feature :in-vector features)
                 (when-let (table (apply #'href-default nil weights feature))
                   (iter (for (class weight) :in-hashtable table)
                         (incf (gethash class scores 0.0) weight))))
           (let ((guess (iter (for (class weight) :in-hashtable scores)
                              (finding class :maximizing weight)))
                 (truth (cond ((= (word-head left) (word-id right))
                               :left-arc)
                              ((= (word-head right) (word-id left))
                               :right-arc)
                              (t :shift))))
             (when (eq guess truth) (incf correct-count))
             (incf total-count)
             (update parser truth guess features)
             (when (and (= (length stack) 1)
                        (= sentence-pointer (1- sentence-len))
                        (member truth '(:left-arc :shift)))
               (setq truth :right-arc))
             (funcall (gethash truth actions)))))
      (values correct-count total-count))))

(defmethod train ((parser dep-parser) sentences &key (cycles 5) save-dir)
  (declare (optimize (speed 3) (space 0) (safety 0)))
  (unless save-dir
    (setq save-dir (asdf/system:system-source-directory :aprnlp)))
  (log-info "Start training with ~D sentences, ~D cycles. ~A"
            (length sentences) cycles
            #+lispworks (lw:string-append "Heap size: " (print-size (getf (sys:room-values) :total-size)))
            #-lispworks "")
  (iter (for cycle :range cycles)
        (let ((correct-count    0)
              (total-count      0)
              (cycle-start-time (get-internal-real-time)))
          (iter (for sentence :in-vector sentences)
                (multiple-value-bind (correct total)
                    (dep-parser-train-sentence parser sentence)
                  (incf correct-count correct)
                  (incf total-count total)))
          (log-info "Cycle ~D/~D completed using ~,2Fs with ~D/~D (~,2F%) correct. ~A"
                    (1+ cycle) cycles
                    #+lispworks (/ (- (get-internal-real-time) cycle-start-time) 1000)
                    #-lispworks (/ (- (get-internal-real-time) cycle-start-time) 1000000)
                    correct-count total-count (* 100.0 (/ correct-count total-count))
                    #+lispworks (lw:string-append "Heap size: " (print-size (getf (sys:room-values) :total-size)))
                    #-lispworks ""))
       (shuffle sentences))
  (average-weights parser)
  (save-processor parser save-dir))

(defmethod test ((parser dep-parser) sentences)
  (let ((correct-count 0)
        (total-count   0)
        (start-time    (get-internal-real-time)))
    (iter (for sentence :in-vector sentences)
          (for new-sentence :next (coerce (iter (for word :in-vector sentence)
                                                (collect (copy-word word)))
                                          'vector))
          (process parser new-sentence)
          (iter (for truth :in-vector sentence)
                (for guess :in-vector new-sentence)
                (when (= (word-head guess) (word-head truth))
                  (incf correct-count))
                (incf total-count)))
    (log-info "Test ~D sentences using ~,2Fs, result: ~D/~D (~,2F%)"
              (length sentences)
              #+lispworks (/ (- (get-internal-real-time) start-time) 1000)
              #-lispworks (/ (- (get-internal-real-time) start-time) 1000000)
              correct-count total-count (* 100 (/ correct-count total-count)))
    (float (* 100 (/ correct-count total-count)))))

(defmethod test-training ((class (eql 'dep-parser)))
  (let ((parser (make-instance 'dep-parser))
        (ud-dir (merge-pathnames "ud-treebanks-v2.14/" (asdf:system-source-directory :aprnlp))))
    (train parser (read-conllu-files (merge-pathnames "UD_English-GUM/en_gum-ud-train.conllu" ud-dir)
                                     (merge-pathnames "UD_English-EWT/en_ewt-ud-train.conllu" ud-dir)
                                     (merge-pathnames "UD_English-Atis/en_atis-ud-train.conllu" ud-dir))
           :cycles 5)
    (test parser (read-conllu-files (merge-pathnames "UD_English-GUM/en_gum-ud-test.conllu" ud-dir)))
    (setq *loaded-dep-parser* parser)))

;(test-training 'dep-parser)