(in-package #:image-backend-stb)

;;; Runs at ASDF load, before the DEFCFUNs. Absolute paths only.

(defun %host-pair ()
  (format nil "~A-~A"
          #+windows "windows" #+darwin "darwin" #+linux "linux"
          #-(or windows darwin linux) "unknown"
          #+(or x86-64 x64) "amd64" #+(or arm64 aarch64) "arm64"
          #-(or x86-64 x64 arm64 aarch64) "unknown"))

(defun %library-name ()
  #+darwin "libstb-cl.dylib" #+windows "stb-cl.dll" #-(or darwin windows) "libstb-cl.so")

(defun %search-dirs ()
  "STB_CL_NATIVE, then the overlay's native/, then lib/<os>-<arch>/."
  (let ((dirs '()) (env (uiop:getenv "STB_CL_NATIVE")))
    (when (and env (plusp (length env)))
      (push (uiop:ensure-directory-pathname env) dirs))
    (let ((system (asdf:find-system "image-backend-stb" nil)))
      (when system
        (let ((root (asdf:system-source-directory system)))
          (push (merge-pathnames "native/" root) dirs)
          (push (merge-pathnames (format nil "lib/~A/" (%host-pair)) root) dirs))))
    (nreverse dirs)))

(defvar *loaded* nil)

(defun load-stb-cl ()
  "Load libstb-cl from the first search directory that has it. Idempotent.
Signals IMAGE-NATIVE-UNAVAILABLE."
  (unless *loaded*
    (let* ((name (%library-name))
           (dir (find-if (lambda (d) (probe-file (merge-pathnames name d))) (%search-dirs))))
      (unless dir
        (error 'img:image-native-unavailable
               :cause (format nil "no ~A in ~{~A~^, ~}" name
                               (mapcar #'namestring (%search-dirs)))))
      (handler-case (cffi:load-foreign-library (namestring (truename (merge-pathnames name dir))))
        (cffi:load-foreign-library-error (e)
          (error 'img:image-native-unavailable :cause (princ-to-string e)))))
    (setf *loaded* t))
  t)

(load-stb-cl)
