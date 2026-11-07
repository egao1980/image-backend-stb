(defpackage #:image-backend-stb/tests
  (:use #:cl #:rove)
  (:local-nicknames (#:img #:image-protocol) (#:stb #:image-backend-stb)))
(in-package #:image-backend-stb/tests)

(defun fixture (name)
  (asdf:system-relative-pathname "image-backend-stb" (format nil "tests/fixtures/~A" name)))

(defun hex-octets (hex)
  (let ((out (make-array (/ (length hex) 2) :element-type '(unsigned-byte 8))))
    (dotimes (i (length out) out)
      (setf (aref out i) (parse-integer hex :start (* 2 i) :end (+ 2 (* 2 i)) :radix 16)))))

(defun expected ()
  (with-open-file (in (fixture "expected.sexp"))
    (with-standard-io-syntax
      (let ((*read-eval* nil))
        (loop for form = (read in nil) while form collect form)))))

(defun psnr (a b)
  "Peak signal-to-noise ratio in dB between two equal-length octet vectors."
  (let ((mse (/ (loop for x across a for y across b sum (expt (- x y) 2)) (length a))))
    (if (zerop mse) 99 (* 10 (log (/ (* 255 255) mse) 10)))))
