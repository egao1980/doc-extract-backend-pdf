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
  "Run BODY as if libpdfium were absent, also when the overlay is staged
   (doc-extract-backend-pdf#11): LOAD-PDFIUM must not find the copy the
   .asd component loaded."
  `(let ((doc-extract-backend-pdf::*pdfium-loaded* nil)
         (doc-extract-backend-pdf::*pdfium-search-enabled* nil)
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

(deftest live-pdfium-unencrypted-without-password
  "doc-extract-backend-pdf#9: the default backend (password slot NIL) must
   open an unencrypted PDF from a pathname (FPDF_LoadDocument) and from
   octets (FPDF_LoadMemDocument). Needs the real libpdfium: stage it with
   ./scripts/stage-pdfium.sh or set PDFIUM_NATIVE to an overlay native/ dir."
  (if (doc-extract-backend-pdf:pdfium-available-p)
      (let ((b (%b))
            (path (uiop:with-temporary-file (:stream s :pathname p :keep t
                                             :type "pdf"
                                             :element-type '(unsigned-byte 8))
                    (write-sequence *hello-pdf* s)
                    p)))
        (unwind-protect
            (progn
              (ok (null (doc-extract-backend-pdf:pdf-password b)))
              (ok (search "Hello pdfium"
                          (doc-extract-protocol:extract-text b path :format :pdf))
                  "pathname source, no password")
              (ok (search "Hello pdfium"
                          (doc-extract-protocol:extract-text b *hello-pdf* :format :pdf))
                  "octet source, no password")
              (ok (equal "Fixture"
                         (getf (doc-extract-protocol:extract-metadata b path :format :pdf)
                               :title))
                  "metadata, no password"))
          (uiop:delete-file-if-exists path)))
      (skip "libpdfium not present: ./scripts/stage-pdfium.sh or PDFIUM_NATIVE=<overlay>/native")))

(deftest live-pdfium-extract
  (if (doc-extract-backend-pdf:pdfium-available-p)
      (let* ((b (%b))
             (text (doc-extract-protocol:extract-text b *hello-pdf* :format :pdf)))
        (ok (search "Hello pdfium" text)))
      (skip "libpdfium not present")))

(deftest live-pdfium-lisp-pathnames
  "evidence: a pathname source names a file the way OPEN does. %WITH-DOCUMENT
   hands (namestring source) to FPDF_LoadDocument, so (1) a relative
   pathname is resolved against the OS working directory instead of
   *DEFAULT-PATHNAME-DEFAULTS* (org-babel binds it to the .org file's
   directory, SLIME / Sly ,cd sets it), and (2) a file name with [ or * gets
   SBCL's namestring escapes (q\\[1].pdf), as every pathname DIRECTORY
   returns for such a file does. PROBE-FILE finds both files; pypdf /
   pypdfium2 open them."
  (if (doc-extract-backend-pdf:pdfium-available-p)
      (let* ((b (%b))
             (dir (uiop:ensure-directory-pathname
                   (merge-pathnames (format nil "pdf-paths-~36r/" (random (expt 36 8)))
                                    (uiop:temporary-directory))))
             (plain (merge-pathnames "hello.pdf" dir))
             (bracket (merge-pathnames (make-pathname :name "q[1]" :type "pdf") dir)))
        (ensure-directories-exist dir)
        (dolist (p (list plain bracket))
          (with-open-file (s p :direction :output :element-type '(unsigned-byte 8)
                               :if-exists :supersede)
            (write-sequence *hello-pdf* s)))
        (flet ((text (source)
                 (handler-case (doc-extract-protocol:extract-text b source :format :pdf)
                   (error (e) (format nil "~a" e)))))
          (unwind-protect
              (progn
                (let ((*default-pathname-defaults* dir))
                  (ok (probe-file #p"hello.pdf") "PROBE-FILE finds the relative pathname")
                  (let ((got (text #p"hello.pdf")))
                    (ok (search "Hello pdfium" got)
                        (format nil "relative pathname under *default-pathname-defaults*: ~s"
                                got))))
                (ok (probe-file bracket) "PROBE-FILE finds q[1].pdf")
                (let ((got (text bracket))
                      (listed (find-if (lambda (p) (search "[" (pathname-name p)))
                                       (directory (merge-pathnames "*.pdf" dir)))))
                  (ok (search "Hello pdfium" got)
                      (format nil "q[1].pdf, namestring ~s: ~s" (namestring bracket) got))
                  (ok (and listed (search "Hello pdfium" (text listed)))
                      (format nil "q[1].pdf as DIRECTORY returns it: ~s" listed))))
            (uiop:delete-file-if-exists plain)
            (uiop:delete-file-if-exists bracket)
            (ignore-errors (uiop:delete-empty-directory dir)))))
      (skip "libpdfium not present: ./scripts/stage-pdfium.sh or PDFIUM_NATIVE=<overlay>/native")))

(deftest password-argument-translation
  "doc-extract-backend-pdf#9 without libpdfium: the FPDF_BYTESTRING
   password type turns NIL into NULL and a string into a C string."
  (let ((type 'doc-extract-backend-pdf::fpdf-bytestring))
    (multiple-value-bind (ptr param) (cffi:convert-to-foreign nil type)
      (ok (cffi:null-pointer-p ptr) "NIL => NULL")
      (cffi:free-converted-object ptr type param))
    (multiple-value-bind (ptr param) (cffi:convert-to-foreign "" type)
      (ok (not (cffi:null-pointer-p ptr)) "\"\" => empty C string")
      (ok (string= "" (cffi:foreign-string-to-lisp ptr)))
      (cffi:free-converted-object ptr type param))
    (multiple-value-bind (ptr param) (cffi:convert-to-foreign "s3cret" type)
      (ok (string= "s3cret" (cffi:foreign-string-to-lisp ptr)))
      (cffi:free-converted-object ptr type param))
    (ok (signals (cffi:convert-to-foreign 42 type) 'type-error))))

(deftest password-must-be-string-or-nil
  (ok (null (doc-extract-backend-pdf:pdf-password (%b))))
  (ok (equal "pw" (doc-extract-backend-pdf:pdf-password (%b :password "pw"))))
  (ok (signals (%b :password 42) 'type-error))
  (ok (signals (%b :password :none) 'type-error)))

(deftest mock-ffi-sees-nil-password
  "The default backend hands NIL (not \"\") to FPDF_Load*Document."
  (let* ((seen '())
         (table (make-mock-ffi))
         (doc-extract-backend-pdf:*pdfium-fn-table*
          (list* :load-mem-document
                 (lambda (buf size password)
                   (declare (ignore buf size))
                   (push (list :mem password) seen)
                   (cffi:make-pointer 1))
                 :load-document
                 (lambda (path password)
                   (declare (ignore path))
                   (push (list :file password) seen)
                   (cffi:make-pointer 1))
                 table)))
    (doc-extract-protocol:extract-text (%b) *hello-pdf* :format :pdf)
    (doc-extract-protocol:extract-text (%b :password "pw") #p"/tmp/x.pdf" :format :pdf)
    (ok (equal '((:file "pw") (:mem nil)) seen))))

(deftest driver-wins-over-native
  "doc-extract-backend-pdf#11: a driver's :extract-sections is used for
   extract-document even when libpdfium (here the mock table) is there."
  (let ((doc-extract-backend-pdf:*pdfium-fn-table* (make-mock-ffi :text "native"))
        (b (%b :driver
               (list :extract-sections
                     (lambda (backend source &key format)
                       (declare (ignore backend source format))
                       (list (doc-extract-protocol:make-extracted-section
                              :title "Page 1" :text "driver" :level 1)))
                     :extract-metadata
                     (lambda (backend source &key format)
                       (declare (ignore backend source format))
                       '(:format :pdf :page-count 1))))))
    (let ((text (doc-extract-protocol:document-text
                 (doc-extract-protocol:extract-document b *hello-pdf* :format :pdf))))
      (ok (search "driver" text) text)
      (ng (search "native" text)))))

(defparameter *locked-pdf*
  (asdf:system-relative-pathname "doc-extract-backend-pdf/tests"
                                 "tests/fixtures/locked-aes128.pdf")
  "AES-128 encrypted, user password \"s3cret\" (fixtures/make-locked-pdf.py).")

(deftest live-pdfium-passwords
  "Encrypted and unencrypted PDFs through the real FFI: no password, empty
   password, right and wrong password, owner password."
  (if (doc-extract-backend-pdf:pdfium-available-p)
      (progn
        (ok (search "Hello pdfium"
                    (doc-extract-protocol:extract-text (%b :password "") *hello-pdf*
                                                       :format :pdf))
            "unencrypted, empty password")
        (ok (search "Hello pdfium"
                    (doc-extract-protocol:extract-text (%b :password "unused") *hello-pdf*
                                                       :format :pdf))
            "unencrypted, password ignored")
        (ok (search "Locked report"
                    (doc-extract-protocol:extract-text (%b :password "s3cret") *locked-pdf*
                                                       :format :pdf))
            "encrypted, user password, pathname")
        (ok (search "Locked report"
                    (doc-extract-protocol:extract-text
                     (%b :password "s3cret")
                     (doc-extract-backend-pdf::%coerce-octets *locked-pdf*)
                     :format :pdf))
            "encrypted, user password, octets")
        (ok (search "Locked report"
                    (doc-extract-protocol:extract-text (%b :password "owner-pw") *locked-pdf*
                                                       :format :pdf))
            "encrypted, owner password")
        (dolist (b (list (%b) (%b :password "wrong")))
          (let ((c (handler-case
                       (progn (doc-extract-protocol:extract-text b *locked-pdf* :format :pdf)
                         nil)
                     (doc-extract-protocol:doc-extract-error (e) e))))
            (ok (typep c 'doc-extract-protocol:doc-extract-error)
                (format nil "password ~S: doc-extract-error"
                        (doc-extract-backend-pdf:pdf-password b)))
            (ng (typep c 'doc-extract-backend-pdf:pdfium-not-loaded))
            (ok (and c (search "password" (princ-to-string c)))
                (princ-to-string c)))))
      (skip "libpdfium not present: ./scripts/stage-pdfium.sh or PDFIUM_NATIVE=<overlay>/native")))
