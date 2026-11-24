(in-package #:doc-extract-backend-pdf)

(define-condition pdf-page-not-found (doc-extract-error)
  ((index :initarg :index :reader pdf-page-not-found-index)
   (page-count :initarg :page-count :reader pdf-page-not-found-page-count))
  (:documentation "RENDER-PAGE was given a page INDEX at or past PAGE-COUNT.")
  (:report (lambda (c s)
             (format s "PDF page index ~D is out of range (~D page~:P)"
                     (pdf-page-not-found-index c)
                     (pdf-page-not-found-page-count c)))))

(define-condition pdfium-not-loaded (doc-extract-unsupported)
  ()
  (:report (lambda (c s)
             (format s "libpdfium is not loaded~@[ format ~a~]~@[: ~a~]"
                     (doc-extract-error-format c)
                     (doc-extract-error-message c)))))
