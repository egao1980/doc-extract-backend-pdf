(in-package #:doc-extract-backend-pdf)

;;; PDFium C subset (fpdfview.h / fpdf_text.h / fpdf_doc.h).
;;; Load is absolute-path only — never LD_LIBRARY_PATH / DYLD_LIBRARY_PATH.
;;; Missing natives must not break ASDF load; GFs signal PDFIUM-NOT-LOADED.
;;; The .asd's optional :native-library "pdfium" component (asdf-native) loads
;;; it from $PDFIUM_NATIVE, native/ or lib/<os>-<arch>/; LOAD-PDFIUM below adds
;;; an explicit file (backend slot or $PDFIUM_LIBRARY) and FPDF_InitLibrary.

(define-foreign-type fpdf-bytestring-type ()
  ()
  (:actual-type :pointer)
  (:simple-parser fpdf-bytestring)
  (:documentation
   "FPDF_BYTESTRING that may be NULL (fpdfview.h: \"If no password is
needed, empty or NULL can be used\"). NIL => NULL pointer, a string =>
a NUL-terminated copy in *DEFAULT-FOREIGN-ENCODING* freed after the
call, a foreign pointer => passed as is. Plain :STRING rejects NIL
(doc-extract-backend-pdf#9)."))

(defmethod translate-to-foreign (value (type fpdf-bytestring-type))
  (etypecase value
    (null (values (null-pointer) nil))
    (string (values (foreign-string-alloc value) t))
    (foreign-pointer (values value nil))))

(defmethod free-translated-object (pointer (type fpdf-bytestring-type) allocated)
  (when allocated
    (foreign-string-free pointer)))

(defcfun ("FPDF_InitLibrary" %fpdf-init-library) :void)
(defcfun ("FPDF_DestroyLibrary" %fpdf-destroy-library) :void)
(defcfun ("FPDF_LoadMemDocument" %fpdf-load-mem-document) :pointer
  (data-buf :pointer)
  (size :int)
  (password fpdf-bytestring))
(defcfun ("FPDF_LoadDocument" %fpdf-load-document) :pointer
  (file-path :string)
  (password fpdf-bytestring))
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

;;; Rasterization (fpdfview.h), used by RENDER-PAGE.
(defcfun ("FPDF_GetPageWidthF" %fpdf-get-page-width-f) :float
  (page :pointer))
(defcfun ("FPDF_GetPageHeightF" %fpdf-get-page-height-f) :float
  (page :pointer))
(defcfun ("FPDFBitmap_CreateEx" %fpdf-bitmap-create-ex) :pointer
  (width :int)
  (height :int)
  (format :int)
  (first-scan :pointer)
  (stride :int))
(defcfun ("FPDFBitmap_FillRect" %fpdf-bitmap-fill-rect) :int
  (bitmap :pointer)
  (left :int)
  (top :int)
  (width :int)
  (height :int)
  (color :unsigned-long))
(defcfun ("FPDF_RenderPageBitmap" %fpdf-render-page-bitmap) :void
  (bitmap :pointer)
  (page :pointer)
  (start-x :int)
  (start-y :int)
  (size-x :int)
  (size-y :int)
  (rotate :int)
  (flags :int))
(defcfun ("FPDFBitmap_GetBuffer" %fpdf-bitmap-get-buffer) :pointer
  (bitmap :pointer))
(defcfun ("FPDFBitmap_GetStride" %fpdf-bitmap-get-stride) :int
  (bitmap :pointer))
(defcfun ("FPDFBitmap_Destroy" %fpdf-bitmap-destroy) :void
  (bitmap :pointer))

(defconstant +fpdfbitmap-bgra+ 4 "FPDFBitmap_BGRA: bytes B G R A, alpha not premultiplied.")
(defconstant +fpdf-annot+ #x01 "FPDF_RenderPageBitmap flag: draw annotations.")
(defconstant +opaque-white+ #xFFFFFFFF "FPDF_DWORD colour 0xAARRGGBB.")

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

(defvar *pdfium-search-enabled* t
  "When NIL, LOAD-PDFIUM neither finds nor initialises libpdfium, even the
   copy the .asd :native-library component already loaded. Bind it with
   *PDFIUM-LOADED* NIL to run the backend as if libpdfium were absent
   (driver / mock-table / PDFIUM-NOT-LOADED paths) in a process that has
   the overlay (doc-extract-backend-pdf#11).")
(defvar *pdfium-fn-table* nil
  "Optional plist of FPDF_* stand-ins for tests. Keys:
   :init-library :destroy-library :load-mem-document :load-document
   :close-document :get-page-count :load-page :close-page
   :text-load-page :text-count-chars :text-get-text :text-close-page
   :get-meta-text :get-last-error; for RENDER-PAGE also :get-page-width-f
   :get-page-height-f :bitmap-create-ex :bitmap-fill-rect :render-page-bitmap
   :bitmap-get-buffer :bitmap-get-stride :bitmap-destroy.")

(defun %env (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun %probe-absolute (path)
  (when path
    (let ((p (probe-file path)))
      (and p (namestring (truename p))))))

(defun %resolve-library-path (&key library-path)
  (or (%probe-absolute library-path)
      (%probe-absolute (%env "PDFIUM_LIBRARY"))))

(defun load-pdfium (&key library-path)
  "Initialise libpdfium. Idempotent. Returns T when loaded. Uses the library
   the .asd component loaded, else LIBRARY-PATH or $PDFIUM_LIBRARY (absolute
   file). Missing library is a soft failure (warn + NIL) so ASDF load cannot crash.
   With *PDFIUM-SEARCH-ENABLED* NIL it loads nothing and returns *PDFIUM-LOADED*."
  (when (and *pdfium-search-enabled* (not *pdfium-loaded*))
    (let* ((component (asdf-native:library-loaded-path "doc-extract-backend-pdf" "pdfium"))
           (abs (unless component (%resolve-library-path :library-path library-path))))
      (when (or component abs)
        (handler-case
            (progn
              (when abs (load-foreign-library abs))
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
    (:get-last-error #'%fpdf-get-last-error)
    (:get-page-width-f #'%fpdf-get-page-width-f)
    (:get-page-height-f #'%fpdf-get-page-height-f)
    (:bitmap-create-ex #'%fpdf-bitmap-create-ex)
    (:bitmap-fill-rect #'%fpdf-bitmap-fill-rect)
    (:render-page-bitmap #'%fpdf-render-page-bitmap)
    (:bitmap-get-buffer #'%fpdf-bitmap-get-buffer)
    (:bitmap-get-stride #'%fpdf-bitmap-get-stride)
    (:bitmap-destroy #'%fpdf-bitmap-destroy)))

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
