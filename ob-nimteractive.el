;;; ob-nimteractive.el --- org-babel backend for persistent Nim sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026 Luis
;; Author: Luis
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; Keywords: languages, nim, org-babel, repl
;; URL: https://github.com/lmbelo/nimteractive

;;; Commentary:
;;
;; org-babel integration for nimteractive — a persistent warm Nim session.
;;
;; Three block types, selected by header args:
;;
;;   :precompile t  — compile imports into the session (run once per session)
;;   :procs t       — define reusable procs; re-execute to hot-reload
;;   (default)      — eval in the warm VM; state accumulates
;;
;; Also provides a comint-based *Nimteractive:<session>* buffer for interactive
;; use, analogous to ESS's *R* buffer.
;;
;; Quick start:
;;
;;   (use-package ob-nimteractive
;;     :vc (:url "~/nimteractive" :lisp-dir ".")
;;     :config
;;     (ob-nimteractive-setup))
;;
;; Then in org-mode add nim to org-babel-load-languages, or just call
;; (ob-nimteractive-setup) which does it automatically.
;;
;; The `nimteractive' binary must be on PATH or set `ob-nimteractive-binary'.
;; Build it with: cd ~/nimteractive && nim c -o:nimteractive src/nimteractive.nim

;;; Code:

(require 'ob)
(require 'comint)
(require 'json)

(defgroup ob-nimteractive nil
  "org-babel nimteractive integration."
  :group 'org-babel
  :prefix "ob-nimteractive-")

(defcustom ob-nimteractive-binary "nimteractive"
  "Path to the nimteractive server binary."
  :type 'string
  :group 'ob-nimteractive)

(defcustom ob-nimteractive-prompt "nim> "
  "Prompt string emitted by the nimteractive server."
  :type 'string
  :group 'ob-nimteractive)

(defcustom ob-nimteractive-timeout 120
  "Seconds to wait for a response before giving up."
  :type 'integer
  :group 'ob-nimteractive)

(defvar ob-nimteractive-default-header-args:nim
  '((:session . "default") (:results . "output"))
  "Default header args for nim src blocks.")

;;; ---------------------------------------------------------------------------
;;; Session process management

(defvar ob-nimteractive--sessions (make-hash-table :test #'equal)
  "Map session-name → process.")

(defun ob-nimteractive--buffer-name (session)
  (format "*Nimteractive:%s*" session))

(defun ob-nimteractive--ensure-session (session)
  "Return a live process for SESSION, starting one if needed."
  (let ((proc (gethash session ob-nimteractive--sessions)))
    (unless (process-live-p proc)
      (setq proc (ob-nimteractive--start-session session)))
    proc))

(defun ob-nimteractive--start-session (session)
  "Start a new nimteractive process for SESSION and return the process."
  (let* ((bufname (ob-nimteractive--buffer-name session))
         (buf (get-buffer-create bufname)))
    (with-current-buffer buf
      (unless (eq major-mode 'comint-mode)
        (comint-mode))
      (setq-local comint-prompt-regexp
                  (regexp-quote ob-nimteractive-prompt))
      (setq-local comint-use-prompt-regexp t)
      ;; Wrap interactive input as JSON before sending to the process
      (setq-local comint-input-sender #'ob-nimteractive--interactive-sender)
      ;; Intercept raw output before comint inserts it into the buffer.
      ;; comint-preoutput-filter-functions uses the return value as the
      ;; replacement string, which is what we need to swap JSON for text.
      (add-hook 'comint-preoutput-filter-functions
                #'ob-nimteractive--output-filter nil t)
      (setq-local ob-nimteractive--session-name session)
      (setq-local ob-nimteractive--pending-output "")
      (setq-local ob-nimteractive--last-response nil)
      (setq-local ob-nimteractive--awaiting-id nil))
    (make-comint-in-buffer
     (format "nimteractive-%s" session)
     buf
     ob-nimteractive-binary)
    (let ((proc (get-buffer-process buf)))
      (puthash session proc ob-nimteractive--sessions)
      proc)))

;;; ---------------------------------------------------------------------------
;;; Interactive input: wrap free-form Nim code as a JSON eval request

(defvar-local ob-nimteractive--interactive-counter 0)

(defun ob-nimteractive--interactive-sender (proc string)
  "Send STRING to PROC as a JSON eval request."
  (cl-incf ob-nimteractive--interactive-counter)
  (let* ((id (format "i%d" ob-nimteractive--interactive-counter))
         (json (json-encode `((op . "eval") (id . ,id) (code . ,string)))))
    (comint-simple-send proc json)))

;;; ---------------------------------------------------------------------------
;;; Output filter: parse JSON responses, display human-readable text

(defvar-local ob-nimteractive--pending-output ""
  "Accumulates partial output lines from the process.")

(defvar-local ob-nimteractive--last-response nil
  "Most recent parsed JSON response (as alist).")

(defvar-local ob-nimteractive--awaiting-id nil
  "ID we are waiting for, or nil if not waiting.")

(defvar-local ob-nimteractive--session-name nil
  "Session name for this buffer.")

(defun ob-nimteractive--output-filter (output)
  "Parse JSON lines from OUTPUT, replace with display text in comint buffer."
  (setq ob-nimteractive--pending-output
        (concat ob-nimteractive--pending-output output))
  (let ((display ""))
    (while (string-match "\n" ob-nimteractive--pending-output)
      (let ((line (substring ob-nimteractive--pending-output
                             0 (match-beginning 0))))
        (setq ob-nimteractive--pending-output
              (substring ob-nimteractive--pending-output (match-end 0)))
        (if (and (> (length line) 0) (eq (aref line 0) ?{))
            ;; Looks like JSON — parse and convert to display text
            (condition-case err
                (let ((resp (json-parse-string line :object-type 'alist)))
                  (setq ob-nimteractive--last-response resp)
                  (when (equal ob-nimteractive--awaiting-id
                               (alist-get 'id resp))
                    (setq ob-nimteractive--awaiting-id nil))
                  (setq display
                        (concat display
                                (ob-nimteractive--resp-to-display resp))))
              (error
               (setq display (concat display line "\n"))))
          ;; Not JSON (e.g. the prompt "nim> ") — pass through
          (setq display (concat display line "\n")))))
    display))

(defun ob-nimteractive--resp-to-display (resp)
  "Convert a parsed JSON response alist to a display string."
  (let ((op (alist-get 'op resp)))
    (cond
     ((string= op "result")
      (let ((out (or (alist-get 'stdout resp) "")))
        (if (string-empty-p out) "" (concat out "\n"))))
     ((string= op "error")
      (format "Error: %s\n" (alist-get 'msg resp)))
     ((string= op "compiling")
      "[compiling...]\n")
     ((string= op "ready")
      (format "[ready — %dms]\n" (or (alist-get 'elapsed_ms resp) 0)))
     ((string= op "reloaded")
      (format "[procs reloaded — %dms]\n"
              (or (alist-get 'elapsed_ms resp) 0)))
     (t ""))))

;;; ---------------------------------------------------------------------------
;;; Send a request and wait for the matching response

(defun ob-nimteractive--send-request (proc request-alist)
  "Send REQUEST-ALIST as JSON to PROC, wait for matching response, return it."
  (let* ((id (format "b%x" (random most-positive-fixnum)))
         (req (json-encode (cons `(id . ,id) request-alist)))
         (buf (process-buffer proc))
         (deadline (+ (float-time) ob-nimteractive-timeout)))
    (with-current-buffer buf
      (setq ob-nimteractive--awaiting-id id))
    (process-send-string proc (concat req "\n"))
    (while (with-current-buffer buf ob-nimteractive--awaiting-id)
      (unless (< (float-time) deadline)
        (with-current-buffer buf (setq ob-nimteractive--awaiting-id nil))
        (error "nimteractive: timeout waiting for response to %s" id))
      (accept-process-output proc 0.05))
    (with-current-buffer buf ob-nimteractive--last-response)))

;;; ---------------------------------------------------------------------------
;;; org-babel execute function

;;;###autoload
(defun org-babel-execute:nim (body params)
  "Execute a nim src block via nimteractive."
  (let* ((session (or (cdr (assq :session params)) "default"))
         (precompile (cdr (assq :precompile params)))
         (procs (cdr (assq :procs params)))
         (proc (ob-nimteractive--ensure-session session)))
    (cond
     (precompile
      (let* ((imports (ob-nimteractive--extract-imports body))
             (resp (ob-nimteractive--send-request
                    proc `((op . "precompile") (imports . ,imports)))))
        (ob-nimteractive--format-babel-result resp)))
     (procs
      (let ((resp (ob-nimteractive--send-request
                   proc `((op . "load_procs") (code . ,body)))))
        (ob-nimteractive--format-babel-result resp)))
     (t
      (let ((resp (ob-nimteractive--send-request
                   proc `((op . "eval") (code . ,body)))))
        (ob-nimteractive--format-babel-result resp))))))

(defun ob-nimteractive--extract-imports (body)
  "Extract module names from import statements in BODY."
  (let (imports)
    (dolist (line (split-string body "\n"))
      (when (string-match "^import +\\(.*\\)" line)
        (dolist (name (split-string (match-string 1 line) "[ ,]+" t))
          (push (string-trim name) imports))))
    (nreverse imports)))

(defun ob-nimteractive--format-babel-result (resp)
  "Format a JSON response for insertion into the org buffer."
  (when resp
    (let ((op (alist-get 'op resp)))
      (cond
       ((string= op "result")
        (string-trim-right (or (alist-get 'stdout resp) "")))
       ((string= op "error")
        (format "Error: %s" (alist-get 'msg resp)))
       ((string= op "ready")
        (format "[session ready — %dms%s]"
                (or (alist-get 'elapsed_ms resp) 0)
                (if (eq (alist-get 'cache_hit resp) t) ", cached" "")))
       ((string= op "reloaded")
        (format "[procs reloaded — %dms]"
                (or (alist-get 'elapsed_ms resp) 0)))
       (t "")))))

;;; ---------------------------------------------------------------------------
;;; Interactive session commands

;;;###autoload
(defun ob-nimteractive-show-session (&optional session)
  "Pop to the *Nimteractive:<SESSION>* comint buffer, starting it if needed.
With prefix arg, prompt for the session name."
  (interactive
   (list (if current-prefix-arg
             (read-string "Session: " "default")
           (or (ob-nimteractive--current-session) "default"))))
  (let* ((name (or session "default"))
         (proc (ob-nimteractive--ensure-session name)))
    (pop-to-buffer (process-buffer proc))))

(defun ob-nimteractive--current-session ()
  "Return the :session value of the nim block at point, or nil."
  (when (org-in-src-block-p)
    (let ((params (nth 2 (org-babel-get-src-block-info))))
      (cdr (assq :session params)))))

;;;###autoload
(defun ob-nimteractive-kill-session (&optional session)
  "Kill the nimteractive session process for SESSION."
  (interactive
   (list (read-string "Session to kill: " "default")))
  (let ((proc (gethash (or session "default")
                       ob-nimteractive--sessions)))
    (when (process-live-p proc)
      (kill-process proc))
    (remhash (or session "default") ob-nimteractive--sessions)))

;;; ---------------------------------------------------------------------------
;;; Setup

;;;###autoload
(defun ob-nimteractive-setup ()
  "Register nim with org-babel.  Call this in your init file.

Avoids going through `org-babel-do-load-languages' because that
calls (require 'ob-nim) which would fail — our file is ob-nimteractive.
Instead we register the execute function directly and add nim to the
load-languages list so org-babel doesn't warn about an unknown language."
  ;; Mark nim as loaded so org-babel-do-load-languages won't try to
  ;; (require 'ob-nim) later if the user calls it themselves.
  (provide 'ob-nim)
  (setq org-babel-load-languages
        (cons '(nim . t)
              (assq-delete-all 'nim org-babel-load-languages))))

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "C-c C-v z")
    #'ob-nimteractive-show-session))

(provide 'ob-nimteractive)
;;; ob-nimteractive.el ends here
