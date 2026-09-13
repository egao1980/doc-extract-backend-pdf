(in-package #:doc-extract-backend-pdf)

;;; PDFium C subset (fpdfview.h / fpdf_text.h / fpdf_doc.h).
;;; Load is absolute-path only — never LD_LIBRARY_PATH / DYLD_LIBRARY_PATH.
;;; Missing natives must not break ASDF load; GFs signal PDFIUM-NOT-LOADED.

(define-foreign-library libpdfium
  (:darwin (:or "libpdfium.dylib" "libpdfium.1.dylib"))
  (:unix (:or "libpdfium.so" "libpdfium.so.1" "libpdfium.so.0"))
  (:windows (:or "pdfium.dll" "libpdfium.dll"))
  (t (:default "libpdfium")))

(defcfun ("FPDF_InitLibrary" %fpdf-init-library) :void)
(defcfun ("FPDF_DestroyLibrary" %fpdf-destroy-library) :void)
(defcfun ("FPDF_LoadMemDocument" %fpdf-load-mem-document) :pointer
  (data-buf :pointer)
  (size :int)
  (password :string))
(defcfun ("FPDF_LoadDocument" %fpdf-load-document) :pointer
  (file-path :string)
  (password :string))
(defcfun ("FPDF_CloseDocument" %fpdf-close-document) :void
  (document :pointer))
(defcfun ("FPDF_GetPageCount" %fpdf-get-page-count) :int
  (document :pointer))
(defcfun ("FPDF_LoadPage" %fpdf-load-page) :pointer
  (document :pointer)
  (page-index :int))
(defcfun ("FPDF_ClosePage" %fpdf-close-page) :void
  (page :pointer))
(defcfun ("FPDFText_LoadPage" %fpdf-text-load-page) :pointer
  (page :pointer))
(defcfun ("FPDFText_CountChars" %fpdf-text-count-chars) :int
  (text-page :pointer))
(defcfun ("FPDFText_GetText" %fpdf-text-get-text) :int
  (text-page :pointer)
  (start-index :int)
  (count :int)
  (result :pointer))
(defcfun ("FPDFText_ClosePage" %fpdf-text-close-page) :void
  (text-page :pointer))
(defcfun ("FPDF_GetMetaText" %fpdf-get-meta-text) :unsigned-long
  (document :pointer)
  (tag :string)
  (buffer :pointer)
  (buflen :unsigned-long))
(defcfun ("FPDF_GetLastError" %fpdf-get-last-error) :unsigned-long)

(defparameter +fpdf-err-names+
  '((0 . "success")
    (1 . "unknown")
    (2 . "file")
    (3 . "format")
    (4 . "password")
    (5 . "security")
    (6 . "page")))

(defvar *pdfium-loaded* nil)
(defvar *pdfium-library-inited* nil)
(defvar *pdfium-fn-table* nil
  "Optional plist of FPDF_* stand-ins for tests. Keys:
   :init-library :destroy-library :load-mem-document :load-document
   :close-document :get-page-count :load-page :close-page
   :text-load-page :text-count-chars :text-get-text :text-close-page
   :get-meta-text :get-last-error.")

(defun %env (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun %host-os ()
  #+windows "windows"
  #+darwin "darwin"
  #+linux "linux"
  #-(or windows darwin linux) "unknown")

(defun %host-arch ()
  #+(or x86-64 x64) "amd64"
  #+(or arm64 aarch64) "arm64"
  #-(or x86-64 x64 arm64 aarch64) "unknown")

(defun %lib-candidates ()
  #+windows '("pdfium.dll" "libpdfium.dll")
  #+darwin '("libpdfium.dylib" "libpdfium.1.dylib")
  #+(and unix (not darwin)) '("libpdfium.so" "libpdfium.so.1" "libpdfium.so.0")
  #-(or windows darwin unix) '("libpdfium.so"))

(defun %find-named (dir names)
  (dolist (name names)
    (let ((p (merge-pathnames name (uiop:ensure-directory-pathname dir))))
      (when (probe-file p)
        (return (namestring (truename p)))))))

(defun %native-search-dirs ()
  "Overlay native/, lib/<os>-<arch>/, optional PDFIUM_NATIVE directory.
   No LD_LIBRARY_PATH / DYLD_LIBRARY_PATH."
  (let ((dirs '()))
    (let ((v (%env "PDFIUM_NATIVE")))
      (when v
        (push v dirs)))
    (ignore-errors
      (let* ((sys (asdf:find-system :doc-extract-backend-pdf nil))
             (root (when sys (asdf:system-source-directory sys))))
        (when root
          (push (namestring (merge-pathnames "native/" root)) dirs)
          (push (namestring
                 (merge-pathnames (format nil "lib/~A-~A/" (%host-os) (%host-arch))
                                  root))
                dirs))))
    (nreverse dirs)))

(defun %probe-absolute (path)
  (when path
    (let ((p (probe-file path)))
      (and p (namestring (truename p))))))

(defun %resolve-library-path (&key library-path)
  (or (%probe-absolute library-path)
      (%probe-absolute (%env "PDFIUM_LIBRARY"))
      (loop for dir in (%native-search-dirs)
            when (and dir (uiop:directory-exists-p dir))
              do (pushnew dir cffi:*foreign-library-directories* :test #'equal)
                 (let ((found (%find-named dir (%lib-candidates))))
                   (when found
                     (return found))))))

(defun load-pdfium (&key library-path)
  "Absolute-path load of libpdfium. Idempotent. Returns T when loaded.
   Never calls LOAD-FOREIGN-LIBRARY unless a file was probed. Missing
   library is a soft failure (warn + NIL) so ASDF load cannot crash."
  (unless *pdfium-loaded*
    (let ((abs (%resolve-library-path :library-path library-path)))
      (when abs
        (handler-case
            (progn
              (load-foreign-library abs)
              (%fpdf-init-library)
              (setf *pdfium-loaded* t
                    *pdfium-library-inited* t))
          (error (e)
            (warn "doc-extract-backend-pdf: libpdfium not loaded (~a). Set PDFIUM_LIBRARY or stage an overlay."
                  e))))))
  *pdfium-loaded*)

(defun pdfium-available-p ()
  (or *pdfium-loaded*
      (and (load-pdfium) *pdfium-loaded*)))

(defun %cffi-fn (name)
  (ecase name
    (:init-library #'%fpdf-init-library)
    (:destroy-library #'%fpdf-destroy-library)
    (:load-mem-document #'%fpdf-load-mem-document)
    (:load-document #'%fpdf-load-document)
    (:close-document #'%fpdf-close-document)
    (:get-page-count #'%fpdf-get-page-count)
    (:load-page #'%fpdf-load-page)
    (:close-page #'%fpdf-close-page)
    (:text-load-page #'%fpdf-text-load-page)
    (:text-count-chars #'%fpdf-text-count-chars)
    (:text-get-text #'%fpdf-text-get-text)
    (:text-close-page #'%fpdf-text-close-page)
    (:get-meta-text #'%fpdf-get-meta-text)
    (:get-last-error #'%fpdf-get-last-error)))

(defun %table-fn (name)
  (and *pdfium-fn-table* (getf *pdfium-fn-table* name)))

(defun %call (name &rest args)
  (let ((fn (%table-fn name)))
    (cond
      (fn (apply fn args))
      (*pdfium-loaded* (apply (%cffi-fn name) args))
      ((eq name :get-last-error) 1)
      (t
       (error 'pdfium-not-loaded
              :format :pdf
              :message (format nil "libpdfium is not loaded (~a)" name))))))

(defun %ensure-inited ()
  (unless *pdfium-library-inited*
    (%call :init-library)
    (setf *pdfium-library-inited* t))
  t)

(defun %null-handle-p (ptr)
  (or (null ptr)
      (and (pointerp ptr) (null-pointer-p ptr))))

(defun %last-error-name ()
  (let* ((code (%call :get-last-error))
         (pair (assoc code +fpdf-err-names+)))
    (if pair
        (cdr pair)
        (format nil "code ~a" code))))

;;; Soft auto-load: overlay consumers get the lib; CI without natives still loads.
(eval-when (:load-toplevel :execute)
  (load-pdfium))
