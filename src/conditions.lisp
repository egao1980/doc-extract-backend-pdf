(in-package #:doc-extract-backend-pdf)

(define-condition pdfium-not-loaded (doc-extract-unsupported)
  ()
  (:report (lambda (c s)
             (format s "libpdfium is not loaded~@[ format ~a~]~@[: ~a~]"
                     (doc-extract-error-format c)
                     (doc-extract-error-message c)))))
