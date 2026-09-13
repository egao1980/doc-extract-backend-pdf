(in-package #:doc-extract-backend-pdf)

(defclass pdf-doc-extract-backend (doc-extract-backend)
  ((cffi-library-path :initarg :cffi-library-path
                      :accessor pdf-cffi-library-path
                      :initform nil)
   (driver :initarg :driver :accessor pdf-driver :initform nil)
   (password :initarg :password :accessor pdf-password :initform nil))
  (:documentation
   "doc-extract-protocol PDF backend. DRIVER is a plist of function
designators (:extract-text :extract-metadata :extract-sections). Without
a driver and without libpdfium, GFs signal PDFIUM-NOT-LOADED
(a DOC-EXTRACT-UNSUPPORTED) with USE-VALUE / RETRY."))

(defun make-pdf-doc-extract-backend (&key cffi-library-path driver password)
  (make-instance 'pdf-doc-extract-backend
                 :cffi-library-path cffi-library-path
                 :driver driver
                 :password password))

(defun use-pdf-doc-extract-backend (&rest args &key &allow-other-keys)
  (setf doc-extract-protocol:*doc-extract-backend*
        (apply #'make-pdf-doc-extract-backend args)))

(defun pdf-driver-loaded-p (backend)
  (and (pdf-driver backend) t))

(defun %resolve-fn (designator)
  (cond
    ((null designator) nil)
    ((functionp designator) designator)
    ((and (symbolp designator) (fboundp designator))
     (fdefinition designator))
    ((and (consp designator) (fboundp (car designator)))
     (fdefinition (car designator)))
    (t
     (error 'doc-extract-error
            :format :pdf
            :message (format nil "invalid pdf driver fn ~s" designator)))))

(defun %driver-fn (backend op)
  (let ((driver (pdf-driver backend)))
    (and driver (%resolve-fn (getf driver op)))))

(defun %pdf-string-p (source)
  (and (stringp source)
       (>= (length source) 4)
       (string= source "%PDF" :end1 4)))

(defun %coerce-octets (source)
  (etypecase source
    ((simple-array (unsigned-byte 8) (*)) source)
    ((vector (unsigned-byte 8))
     (make-array (length source)
                 :element-type '(unsigned-byte 8)
                 :initial-contents source))
    (pathname
     (with-open-file (in source :element-type '(unsigned-byte 8)
                                :if-does-not-exist :error)
       (let ((buf (make-array (file-length in)
                              :element-type '(unsigned-byte 8))))
         (read-sequence buf in)
         buf)))
    (string
     (if (%pdf-string-p source)
         (map '(simple-array (unsigned-byte 8) (*)) #'char-code source)
         (%coerce-octets (pathname source))))))

(defun %path-source-p (source)
  (and (not (typep source '(vector (unsigned-byte 8))))
       (not (%pdf-string-p source))
       (or (pathnamep source) (stringp source))))

(defun %text-page-string (text-page)
  (let ((n (%call :text-count-chars text-page)))
    (cond
      ((or (null n) (not (plusp n))) "")
      (t
       (with-foreign-object (buf :uint16 (1+ n))
         (dotimes (i (1+ n))
           (setf (mem-aref buf :uint16 i) 0))
         (%call :text-get-text text-page 0 n buf)
         (or (foreign-string-to-lisp buf :encoding :utf-16le) ""))))))

(defun %page-text (doc index)
  (let ((page (%call :load-page doc index)))
    (when (%null-handle-p page)
      (return-from %page-text ""))
    (unwind-protect
         (let ((tp (%call :text-load-page page)))
           (if (%null-handle-p tp)
               ""
               (unwind-protect
                    (%text-page-string tp)
                 (%call :text-close-page tp))))
      (%call :close-page page))))

(defun %document-text (doc)
  (let ((n (or (%call :get-page-count doc) 0)))
    (with-output-to-string (s)
      (dotimes (i n)
        (let ((piece (%page-text doc i)))
          (when (and (plusp i) (plusp (length piece)))
            (terpri s))
          (write-string piece s))))))

(defparameter +meta-tags+
  '(("Title" . :title)
    ("Author" . :author)
    ("Subject" . :subject)
    ("Keywords" . :keywords)
    ("Creator" . :creator)
    ("Producer" . :producer)
    ("CreationDate" . :creation-date)
    ("ModDate" . :mod-date)))

(defun %meta-text (doc tag)
  (let ((nbytes (%call :get-meta-text doc tag (null-pointer) 0)))
    (when (and nbytes (> nbytes 2))
      (with-foreign-object (buf :uint8 nbytes)
        (dotimes (i nbytes)
          (setf (mem-aref buf :uint8 i) 0))
        (%call :get-meta-text doc tag buf nbytes)
        (let ((s (foreign-string-to-lisp buf :encoding :utf-16le)))
          (when (and s (plusp (length s)))
            s))))))

(defun %document-metadata (doc)
  (let ((md (list :format :pdf
                  :page-count (or (%call :get-page-count doc) 0))))
    (dolist (pair +meta-tags+ md)
      (let ((value (%meta-text doc (car pair))))
        (when value
          (setf (getf md (cdr pair)) value))))))

(defun %document-sections (doc)
  (let ((n (or (%call :get-page-count doc) 0))
        (sections '()))
    (dotimes (i n)
      (push (make-extracted-section
             :title (format nil "Page ~D" (1+ i))
             :text (%page-text doc i)
             :level 1)
            sections))
    (nreverse sections)))

(defun %with-document (source password fn)
  (%ensure-inited)
  (labels ((run (doc)
             (when (%null-handle-p doc)
               (error 'doc-extract-error
                      :format :pdf
                      :message (format nil "failed to load PDF (~a)"
                                       (%last-error-name))))
             (unwind-protect
                  (funcall fn doc)
               (%call :close-document doc))))
    (if (%path-source-p source)
        (run (%call :load-document
                    (if (pathnamep source)
                        (namestring source)
                        source)
                    password))
        (let ((octets (%coerce-octets source)))
          (with-pointer-to-vector-data (ptr octets)
            (run (%call :load-mem-document ptr (length octets) password)))))))

(defun %extract-text-native (backend source)
  (%with-document source (pdf-password backend) #'%document-text))

(defun %extract-metadata-native (backend source)
  (%with-document source (pdf-password backend) #'%document-metadata))

(defun %extract-sections-native (backend source)
  (%with-document source (pdf-password backend) #'%document-sections))

(defun %extract (backend source op native-fn &rest keys)
  (tagbody
   :again
     (let ((fn (%driver-fn backend op)))
       (when fn
         (return-from %extract (apply fn backend source keys))))
     (when (pdf-cffi-library-path backend)
       (load-pdfium :library-path (pdf-cffi-library-path backend)))
     (when (or *pdfium-fn-table* *pdfium-loaded*)
       (return-from %extract (funcall native-fn backend source)))
     (restart-case
         (error 'pdfium-not-loaded
                :format :pdf
                :message "libpdfium is not loaded")
       (use-value (value)
         :report "Use a supplied extracted value"
         :interactive (lambda ()
                        (format *query-io* "Value: ")
                        (force-output *query-io*)
                        (list (read *query-io*)))
         (return-from %extract value))
       (retry ()
         :report "Retry after loading libpdfium or installing a driver"
         (go :again)))))

(defmethod extract-metadata :around ((backend pdf-doc-extract-backend) source
                                     &key format)
  (restart-case (call-next-method)
    (use-value (value)
      :report "Use a supplied metadata plist"
      value)
    (retry ()
      :report "Retry extract-metadata"
      (extract-metadata backend source :format format))))

(defmethod extract-sections :around ((backend pdf-doc-extract-backend) source
                                     &key format)
  (restart-case (call-next-method)
    (use-value (value)
      :report "Use a supplied section list"
      value)
    (retry ()
      :report "Retry extract-sections"
      (extract-sections backend source :format format))))

(defmethod extract-text ((backend pdf-doc-extract-backend) source &key format)
  (%extract backend source :extract-text #'%extract-text-native :format format))

(defmethod extract-metadata ((backend pdf-doc-extract-backend) source &key format)
  (%extract backend source :extract-metadata #'%extract-metadata-native
            :format format))

(defmethod extract-sections ((backend pdf-doc-extract-backend) source &key format)
  (%extract backend source :extract-sections #'%extract-sections-native
            :format format))
