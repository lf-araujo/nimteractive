;;; ob-nimteractive.el --- org-babel backend for nimteractive sessions -*- lexical-binding: t -*-

;;; Commentary:
;; Provides org-babel integration for nimteractive.
;; Three block types driven by header args:
;;   :precompile t  — compile core binary from import list (run once)
;;   :procs t       — hot-reload procs .so on every execution
;;   (default)      — eval block in the warm VM
;;
;; Also provides a comint-based *Nimteractive* buffer for interactive use,
;; analogous to ESS's *R* buffer.

;;; Code:

(require 'ob)
(require 'comint)
(require 'json)

(defgroup ob-nimteractive nil
  "org-babel nimteractive integration."
  :group 'org-babel)

(defcustom ob-nimteractive-binary "nimteractive"
  "Path to the nimteractive server binary."
  :type 'string
  :group 'ob-nimteractive)

;; ---------------------------------------------------------------------------
;; Session process management

(defvar ob-nimteractive--sessions (make-hash-table :test #'equal)
  "Map of session name → process.")

(defun ob-nimteractive--session-buffer (name)
  (format "*Nimteractive:%s*" name))

(defun ob-nimteractive--ensure-session (name)
  "Return a live process for SESSION, starting one if needed."
  (let ((proc (gethash name ob-nimteractive--sessions)))
    (unless (process-live-p proc)
      (let* ((bufname (ob-nimteractive--session-buffer name))
             (buf (get-buffer-create bufname)))
        (with-current-buffer buf
          (unless (eq major-mode 'comint-mode)
            (comint-mode))
          (setq proc (make-comint-in-buffer
                      (format "nimteractive-%s" name)
                      buf
                      ob-nimteractive-binary)))
        (puthash name proc ob-nimteractive--sessions)
        ;; Install output filter for sentinel scraping
        (with-current-buffer buf
          (add-hook 'comint-output-filter-functions
                    #'ob-nimteractive--output-filter nil t))))
    proc))

;; ---------------------------------------------------------------------------
;; Output filtering — intercept JSON responses, pass rest to comint

(defvar-local ob-nimteractive--pending nil
  "Buffer for accumulating partial JSON lines from the process.")

(defvar-local ob-nimteractive--last-response nil
  "Most recent parsed JSON response.")

(defvar-local ob-nimteractive--waiting nil
  "Non-nil when ob is waiting for a response with this id.")

(defun ob-nimteractive--output-filter (output)
  "Filter process output: intercept JSON lines, pass display text through."
  (setq ob-nimteractive--pending
        (concat ob-nimteractive--pending output))
  (let ((display ""))
    (while (string-match "\n" ob-nimteractive--pending)
      (let ((line (substring ob-nimteractive--pending 0 (match-beginning 0))))
        (setq ob-nimteractive--pending
              (substring ob-nimteractive--pending (match-end 0)))
        (condition-case nil
            (let ((resp (json-parse-string line :object-type 'alist)))
              (setq ob-nimteractive--last-response resp)
              (when (and ob-nimteractive--waiting
                         (string= ob-nimteractive--waiting
                                  (alist-get 'id resp)))
                (setq ob-nimteractive--waiting nil)))
          ;; Not JSON → display as-is
          (error (setq display (concat display line "\n"))))))
    display))

;; ---------------------------------------------------------------------------
;; Request/response

(defun ob-nimteractive--send (proc request-alist &optional timeout)
  "Send REQUEST-ALIST as JSON to PROC, wait for matching response."
  (let* ((id (format "%x" (random most-positive-fixnum)))
         (req (json-encode (cons `(id . ,id) request-alist)))
         (buf (process-buffer proc))
         (deadline (+ (float-time) (or timeout 60.0))))
    (with-current-buffer buf
      (setq ob-nimteractive--waiting id))
    (process-send-string proc (concat req "\n"))
    (while (and (with-current-buffer buf ob-nimteractive--waiting)
                (< (float-time) deadline))
      (accept-process-output proc 0.05))
    (with-current-buffer buf ob-nimteractive--last-response)))

;; ---------------------------------------------------------------------------
;; org-babel entry point

;;;###autoload
(defun org-babel-execute:nim (body params)
  "Execute a nim src block via nimteractive."
  (let* ((session (or (cdr (assq :session params)) "default"))
         (precompile (cdr (assq :precompile params)))
         (procs (cdr (assq :procs params)))
         (proc (ob-nimteractive--ensure-session session)))
    (cond
     ;; :precompile t — extract import lines, compile core
     (precompile
      (let* ((imports (ob-nimteractive--extract-imports body))
             (resp (ob-nimteractive--send
                    proc `((op . "precompile") (imports . ,imports)) 120.0)))
        (ob-nimteractive--format-result resp)))
     ;; :procs t — hot-reload procs .so
     (procs
      (let ((resp (ob-nimteractive--send
                   proc `((op . "load_procs") (code . ,body)) 60.0)))
        (ob-nimteractive--format-result resp)))
     ;; default — eval in warm VM
     (t
      (let ((resp (ob-nimteractive--send
                   proc `((op . "eval") (code . ,body)) 30.0)))
        (ob-nimteractive--format-result resp))))))

(defun ob-nimteractive--extract-imports (body)
  "Extract import names from a block like 'import foo, bar\\nimport baz'."
  (let (imports)
    (dolist (line (split-string body "\n"))
      (when (string-match "^import +\\(.*\\)" line)
        (dolist (imp (split-string (match-string 1 line) "[ ,]+"))
          (let ((imp (string-trim imp)))
            (unless (string-empty-p imp)
              (push imp imports))))))
    (nreverse imports)))

(defun ob-nimteractive--format-result (resp)
  "Format a JSON response alist as a string for the org buffer."
  (when resp
    (let ((op (alist-get 'op resp)))
      (cond
       ((string= op "result")
        (let ((out (alist-get 'stdout resp))
              (val (alist-get 'value resp)))
          (string-trim (concat out (if (string-empty-p val) "" (concat "\n" val))))))
       ((string= op "error")
        (format "ERROR: %s" (alist-get 'msg resp)))
       ((string= op "ready")
        (format "[core ready — cache %s, %dms]"
                (if (eq (alist-get 'cache_hit resp) t) "hit" "miss")
                (alist-get 'elapsed_ms resp 0)))
       ((string= op "reloaded")
        (format "[procs reloaded — %dms]" (alist-get 'elapsed_ms resp 0)))
       (t (format "%s" resp))))))

;; ---------------------------------------------------------------------------
;; Interactive session buffer (ESS-style)

;;;###autoload
(defun ob-nimteractive-show-session (&optional session)
  "Switch to or create the *Nimteractive* comint buffer.
With prefix arg, prompt for SESSION name."
  (interactive
   (list (if current-prefix-arg
             (read-string "Session name: " "default")
           "default")))
  (let* ((name (or session "default"))
         (proc (ob-nimteractive--ensure-session name))
         (buf (process-buffer proc)))
    (pop-to-buffer buf)))

(defun ob-nimteractive-kill-session (&optional session)
  "Kill the nimteractive session process."
  (interactive
   (list (read-string "Session name: " "default")))
  (let ((proc (gethash (or session "default") ob-nimteractive--sessions)))
    (when (process-live-p proc)
      (kill-process proc))
    (remhash (or session "default") ob-nimteractive--sessions)))

;; Default keybinding in org-mode buffers
(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c C-v z") #'ob-nimteractive-show-session))

(provide 'ob-nimteractive)
;;; ob-nimteractive.el ends here
