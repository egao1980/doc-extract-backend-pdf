(in-package #:doc-extract-backend-pdf/tests)

(defun %b (&rest args)
  (apply #'doc-extract-backend-pdf:make-pdf-doc-extract-backend args))

(defun make-hello-pdf-octets (&optional (text "Hello pdfium"))
  "Hand-made valid PDF-1.1 with a single Helvetica text run + Info dict."
  (flet ((esc (s)
           (with-output-to-string (o)
             (loop for c across s
                   do (case c
                        (#\\ (write-string "\\\\" o))
                        (#\( (write-string "\\(" o))
                        (#\) (write-string "\\)" o))
                        (t (write-char c o)))))))
    (let* ((content (format nil "BT /F1 12 Tf 72 720 Td (~A) Tj ET" (esc text)))
           (objs
            (list
             "<< /Type /Catalog /Pages 2 0 R >>"
             "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
             "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
             (format nil "<< /Length ~D >>~%stream~%~A~%endstream"
                     (length content) content)
             "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
             "<< /Title (Fixture) /Author (egao1980) >>"))
           (header (format nil "%PDF-1.1~%"))
           (chunks '())
           (offsets (list 0))
           (pos (length header)))
      (loop for i from 1
            for body in objs
            for chunk = (format nil "~D 0 obj~%~A~%endobj~%" i body)
            do (push pos offsets)
               (push chunk chunks)
               (incf pos (length chunk)))
      (let* ((body (apply #'concatenate 'string (nreverse chunks)))
             (startxref pos)
             (off (nreverse offsets))
             (xref (with-output-to-string (s)
                     (format s "xref~%0 ~D~%" (1+ (length objs)))
                     (format s "0000000000 65535 f ~%")
                     (dolist (o (rest off))
                       (format s "~10,'0D 00000 n ~%" o))
                     (format s "trailer~%<< /Size ~D /Root 1 0 R /Info 6 0 R >>~%startxref~%~D~%%%EOF~%"
                             (1+ (length objs)) startxref))))
        (map '(simple-array (unsigned-byte 8) (*))
             #'char-code
             (concatenate 'string header body xref))))))

(defparameter *hello-pdf* (make-hello-pdf-octets))

(defun %utf16-write (string buf buflen)
  (cffi:lisp-string-to-foreign string buf (max buflen 2) :encoding :utf-16le)
  (* 2 (1+ (length string))))

(defun make-mock-ffi (&key (text "Hello pdfium")
                           texts
                           (title "Fixture")
                           (author "egao1980"))
  (let* ((pages (or texts (list text)))
         (current 0))
    (list :init-library (lambda () t)
          :destroy-library (lambda () t)
          :load-mem-document
          (lambda (data-buf size password)
            (declare (ignore data-buf size password))
            (cffi:make-pointer 1))
          :load-document
          (lambda (path password)
            (declare (ignore path password))
            (cffi:make-pointer 1))
          :close-document (lambda (doc) (declare (ignore doc)) t)
          :get-page-count (lambda (doc) (declare (ignore doc)) (length pages))
          :load-page
          (lambda (doc index)
            (declare (ignore doc))
            (setf current index)
            (cffi:make-pointer 2))
          :close-page (lambda (page) (declare (ignore page)) t)
          :text-load-page
          (lambda (page)
            (declare (ignore page))
            (cffi:make-pointer 3))
          :text-count-chars
          (lambda (text-page)
            (declare (ignore text-page))
            (length (or (nth current pages) "")))
          :text-get-text
          (lambda (text-page start count buf)
            (declare (ignore text-page start))
            (let* ((text (or (nth current pages) ""))
                   (n (min count (length text))))
              (%utf16-write (subseq text 0 n) buf (* 2 (1+ n)))
              (1+ n)))
          :text-close-page (lambda (text-page) (declare (ignore text-page)) t)
          :get-meta-text
          (lambda (doc tag buf buflen)
            (declare (ignore doc))
            (let ((s (cond ((string= tag "Title") title)
                           ((string= tag "Author") author)
                           (t ""))))
              (if (or (cffi:null-pointer-p buf) (zerop buflen))
                  (* 2 (1+ (length s)))
                  (%utf16-write s buf buflen))))
          :get-last-error (lambda () 0))))

(deftest available-p-does-not-crash
  (ok (member (doc-extract-backend-pdf:pdfium-available-p) '(t nil))))

(deftest fixture-is-minimal-pdf
  (ok (>= (length *hello-pdf*) 8))
  (ok (equalp (subseq *hello-pdf* 0 5)
              (map '(vector (unsigned-byte 8)) #'char-code "%PDF-")))
  (ok (search #(37 37 69 79 70) *hello-pdf* :from-end t))) ; %%EOF

(defmacro %without-pdfium (&body body)
  `(let ((doc-extract-backend-pdf::*pdfium-loaded* nil)
         (doc-extract-backend-pdf:*pdfium-fn-table* nil))
     ,@body))

(deftest missing-library-signals
  (%without-pdfium
    (let ((b (%b)))
      (ng (doc-extract-backend-pdf:pdf-driver-loaded-p b))
      (dolist (fn (list #'doc-extract-protocol:extract-text
                        #'doc-extract-protocol:extract-metadata
                        #'doc-extract-protocol:extract-sections
                        #'doc-extract-protocol:extract-document))
        (ok (signals (funcall fn b "x.pdf" :format :pdf)
                     'doc-extract-protocol:doc-extract-unsupported))
        (ok (signals (funcall fn b "x.pdf" :format :pdf)
                     'doc-extract-backend-pdf:pdfium-not-loaded))))))

(deftest missing-library-use-value-text
  (%without-pdfium
    (let ((b (%b))
          (got :unset))
      (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                      (lambda (c)
                        (use-value "fallback" c))))
        (setf got (doc-extract-protocol:extract-text b "x.pdf" :format :pdf)))
      (ok (string= "fallback" got)))))

(deftest missing-library-use-value-metadata
  (%without-pdfium
    (let ((b (%b))
          (got :unset))
      (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                      (lambda (c)
                        (use-value '(:format :pdf :title "fallback") c))))
        (setf got (doc-extract-protocol:extract-metadata b "x.pdf" :format :pdf)))
      (ok (equal '(:format :pdf :title "fallback") got)))))

(deftest missing-library-use-value-sections
  (%without-pdfium
    (let ((b (%b))
          (got :unset))
      (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                      (lambda (c)
                        (use-value '() c))))
        (setf got (doc-extract-protocol:extract-sections b "x.pdf" :format :pdf)))
      (ok (null got)))))

(deftest missing-library-retry
  (%without-pdfium
    (let* ((b (%b))
           (got :unset)
           (attempts 0))
      (handler-bind ((doc-extract-protocol:doc-extract-unsupported
                      (lambda (c)
                        (incf attempts)
                        (when (= attempts 1)
                          (setf (doc-extract-backend-pdf:pdf-driver b)
                                (list :extract-text
                                      (lambda (backend source &key format)
                                        (declare (ignore backend source format))
                                        "retried")))
                          (invoke-restart
                           (find-if (lambda (r)
                                      (and (restart-name r)
                                           (string= (restart-name r) "RETRY")))
                                    (compute-restarts c)))))))
        (setf got (doc-extract-protocol:extract-text b "x.pdf" :format :pdf)))
      (ok (string= "retried" got))
      (ok (= 1 attempts)))))

(deftest fake-driver-extract-from-fixture
  (let* ((seen nil)
         (b (%b :driver
                (list :extract-text
                      (lambda (backend source &key format)
                        (declare (ignore backend))
                        (setf seen (list source format))
                        "Hello pdfium")
                      :extract-metadata
                      (lambda (backend source &key format)
                        (declare (ignore backend source format))
                        '(:format :pdf :title "Fixture" :author "egao1980"))
                      :extract-sections
                      (lambda (backend source &key format)
                        (declare (ignore backend source format))
                        (list (doc-extract-protocol:make-extracted-section
                               :title "Page 1"
                               :text "Hello pdfium"
                               :level 1)))))))
    (ok (doc-extract-backend-pdf:pdf-driver-loaded-p b))
    (ok (string= "Hello pdfium"
                 (doc-extract-protocol:extract-text b *hello-pdf* :format :pdf)))
    (ok (eq *hello-pdf* (first seen)))
    (ok (eq :pdf (second seen)))
    (let ((md (doc-extract-protocol:extract-metadata b *hello-pdf* :format :pdf)))
      (ok (eq :pdf (getf md :format)))
      (ok (equal "Fixture" (getf md :title))))
    (let ((secs (doc-extract-protocol:extract-sections b *hello-pdf* :format :pdf)))
      (ok (= 1 (length secs)))
      (ok (doc-extract-protocol:extracted-section-p (first secs)))
      (ok (search "Hello pdfium"
                  (doc-extract-protocol:section-text (first secs)))))
    (let* ((doc (doc-extract-protocol:extract-document b *hello-pdf* :format :pdf))
           (pages (doc-extract-protocol:extracted-document-pages doc))
           (blocks (doc-extract-protocol:extracted-document-blocks doc)))
      (ok (doc-extract-protocol:extracted-document-p doc))
      (ok (plusp (length pages)))
      (ok (= 1 (doc-extract-protocol:page-info-number (first pages))))
      (ok (plusp (length blocks)))
      (ok (every #'doc-extract-protocol:block-id blocks)))))

(deftest mocked-ffi-extract-text
  (let ((doc-extract-backend-pdf:*pdfium-fn-table* (make-mock-ffi))
        (b (%b)))
    (ok (string= "Hello pdfium"
                 (doc-extract-protocol:extract-text b *hello-pdf* :format :pdf)))
    (let ((md (doc-extract-protocol:extract-metadata b *hello-pdf* :format :pdf)))
      (ok (eq :pdf (getf md :format)))
      (ok (equal "Fixture" (getf md :title)))
      (ok (equal "egao1980" (getf md :author)))
      (ok (= 1 (getf md :page-count))))
    (let ((secs (doc-extract-protocol:extract-sections b *hello-pdf* :format :pdf)))
      (ok (= 1 (length secs)))
      (ok (equal "Page 1" (doc-extract-protocol:section-title (first secs))))
      (ok (string= "Hello pdfium"
                   (doc-extract-protocol:section-text (first secs)))))
    (let* ((doc (doc-extract-protocol:extract-document b *hello-pdf* :format :pdf))
           (pages (doc-extract-protocol:extracted-document-pages doc))
           (root (first (doc-extract-protocol:extracted-document-blocks doc)))
           (kid (and root (first (doc-extract-protocol:section-children root)))))
      (ok (doc-extract-protocol:extracted-document-p doc))
      (ok (= 1 (length pages)))
      (ok (= 1 (doc-extract-protocol:page-info-number (first pages))))
      (ok (stringp (doc-extract-protocol:block-id root)))
      (ok (plusp (length (doc-extract-protocol:block-id root))))
      (ok (and kid (stringp (doc-extract-protocol:block-id kid))))
      (ok (equal 1 (doc-extract-protocol:provenance-entry-page
                    (first (doc-extract-protocol:block-provenance root)))))
      (ok (search "Hello pdfium" (doc-extract-protocol:document-text doc))))))

(deftest registers-pdf-at-pdfium-priority
  (ok (= 20 doc-extract-backend-pdf:+pdfium-extractor-priority+))
  (ok (typep (doc-extract-protocol:find-extractor :pdf)
             'doc-extract-backend-pdf:pdf-doc-extract-backend))
  (ok (typep (doc-extract-protocol:find-extractor "application/pdf")
             'doc-extract-backend-pdf:pdf-doc-extract-backend)))

(deftest mocked-ffi-extract-document-multipage
  (let ((doc-extract-backend-pdf:*pdfium-fn-table*
         (make-mock-ffi :texts '("First page" "Second page")))
        (b (%b)))
    (let* ((doc (doc-extract-protocol:extract-document b *hello-pdf* :format :pdf))
           (pages (doc-extract-protocol:extracted-document-pages doc))
           (blocks (doc-extract-protocol:extracted-document-blocks doc)))
      (ok (doc-extract-protocol:extracted-document-p doc))
      (ok (= 2 (length pages)))
      (ok (= 2 (length blocks)))
      (ok (every #'doc-extract-protocol:block-id blocks))
      (ok (search "First page" (doc-extract-protocol:document-text doc)))
      (ok (search "Second page" (doc-extract-protocol:document-text doc))))))

(deftest backend-slot-path-is-recorded
  (%without-pdfium
    (let ((b (%b :cffi-library-path "/no/such/libpdfium.so")))
      (ok (equal "/no/such/libpdfium.so"
                 (doc-extract-backend-pdf:pdf-cffi-library-path b)))
      (ok (signals (doc-extract-protocol:extract-text b "x.pdf" :format :pdf)
                   'doc-extract-backend-pdf:pdfium-not-loaded)))))

(deftest live-pdfium-extract
  (if (doc-extract-backend-pdf:pdfium-available-p)
      (let* ((b (%b))
             (text (doc-extract-protocol:extract-text b *hello-pdf* :format :pdf)))
        (ok (search "Hello pdfium" text)))
      (skip "libpdfium not present")))
