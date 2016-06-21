;;; cedille-mode.el --- Major mode for Cedille
;;;
;;; You need to set cedille-path to be the path to your Cedille installation.
;;; Then add that path to your load path for emacs.
;;; Then put (require 'cedille-mode) in your .emacs file. 
;;; 
;;; For example:
;;;
;;;    (setq cedille-path "/home/astump/cedille")
;;;    (add-to-list 'load-path cedille-path)
;;;    (require 'cedille-mode)
;;;

(require 'quail)

;(defvar cedille-program-name (concat cedille-path "/mock-cedille.sh"))
(defvar cedille-program-name (concat cedille-path "/cedille"))
(setq max-lisp-eval-depth 30000)
(setq max-specpdl-size 30000)

(defvar cedille-mode-debug nil "If non-nil then print information for developers")

(autoload 'cedille-mode "cedille-mode" "Major mode for editing cedille files ." t)
(add-to-list 'auto-mode-alist (cons "\\.ced\\'" 'cedille-mode))

(let ((se-path (concat cedille-path "/se-mode")))
  (add-to-list 'load-path se-path)
  (add-to-list 'load-path (concat se-path "/json.el")))
(load-library "se")



(when (version< emacs-version "24.4")
  (defun define-error (name message &optional parent)
    "Define NAME as a new error signal.
MESSAGE is a string that will be output to the echo area if such an error
is signaled without being caught by a `condition-case'.
PARENT is either a signal or a list of signals from which it inherits.
Defaults to `error'."
    (unless parent (setq parent 'error))
    (let ((conditions
           (if (consp parent)
               (apply #'nconc
                      (mapcar (lambda (parent)
                                (cons parent
                                      (or (get parent 'error-conditions)
                                          (error "Unknown signal `%s'" parent))))
                              parent))
             (cons parent (get parent 'error-conditions)))))
      (put name 'error-conditions
           (delete-dups (copy-sequence (cons name conditions))))
      (when message (put name 'error-message message)))))

(require 'se-mode)
(eval-when-compile (require 'se-macros))

(defvar cedille-mode-version "1.0"
  "The version of the cedille mode.")

(defvar cedille-mode-debug nil
  "Show debugging spans in cedille mode.")

; set in .emacs file
(defvar cedille-program-name "cedille-executable"
  "Program to run for cedille mode.")

(defvar cedille-info-buffer-trailing-edge 1 "Number of blank lines to insert at the bottom of the info buffer.")

(defun cedille-info-buffer-name() (concat "*cedille-info-" (file-name-base (buffer-name)) "*"))

(defun cedille-info-buffer()
  (let* ((n (cedille-info-buffer-name))
         (b (get-buffer-create n)))
    (with-current-buffer b
       (setq buffer-read-only nil))
    b))

(defun cedille-adjust-info-window-size()
  (let ((w (get-buffer-window (cedille-info-buffer))))
   (when w
     (fit-window-to-buffer w)
     (unless (eq (window-resizable w cedille-info-buffer-trailing-edge) 0)
         (window-resize w cedille-info-buffer-trailing-edge)))))

(defun cedille-mode-concat-sep(sep ss)
  "Concat the strings in nonempty list ss with sep in between each one."
  (let ((he (car ss))
        (ta (cdr ss)))
    (if (not ta) he
      (concat he sep (cedille-mode-concat-sep sep ta)))))

(defun cedille-mode-split-string(s)
  "Return a pair of the prefix of the string up to the first space, 
and the remaining suffix."
  (let ((ss (split-string s " ")))
    (if (< (length ss) 2) s
      (cons (car ss) (cedille-mode-concat-sep " " (cdr ss))))))

(defun cedille-mode-get-seqnum(a)
  "Get the seqnum from a json pair. The second component
is assumed to be a string with a sequence number (prefix up
 to the first space in each string)."
  (car (cedille-mode-split-string (cdr a))))

(defun cedille-mode-compare-seqnums(a b)
  "Compare two pairs by seqnum."
  (let ((na (cedille-mode-get-seqnum a))
        (nb (cedille-mode-get-seqnum b)))
      (< (string-to-number na) (string-to-number nb))))

(defun cedille-mode-strip-seqnum(s)
  "Return a new string just like s except without the prefix up to the 
first space."
  (cdr (cedille-mode-split-string s)))

(defun cedille-mode-sort-and-strip-json(json)
  "Sort the pairs in the JSON data by the number at the 
start of each string, and then strip out that number."
  (when json
      (setq json (sort json 'cedille-mode-compare-seqnums))
      (setq json (loop for (key . value) in json
                   collecting (cons key (cedille-mode-strip-seqnum value))))
      json))

(defun cedille-mode-initialize-span(span)
  "Initialize the given span read in by se-mode."
  (when span
    (se-new-span (se-span-name span) (se-span-start span) (se-span-end span)
      (cedille-mode-sort-and-strip-json (se-span-data span)))))

(defun cedille-mode-initialize-spans()
  "Initialize spans after they are read in by se-mode."
  (setq se-mode-spans (mapcar #'cedille-mode-initialize-span se-mode-spans)))

(defun cedille-mode-filter-out-special(data)
  "Filter out special attributes from the data in a span"
  (loop for (key . value) in data
     unless (or (eq key 'symbol) (eq key 'location))
     collecting (cons key value)))

(defun cedille-mode-inspect ()
  "Displays information on the currently selected node in 
the info buffer for the file.  Return the info buffer as a convenience."
  (interactive)
  (when se-mode-selected
    (let* ((b (cedille-info-buffer))
           (d (se-term-to-json (se-mode-selected)))
           (txt (se-mode-pretty-json (if cedille-mode-debug d (cedille-mode-filter-out-special d)))))
      (with-current-buffer b
         (erase-buffer)
         (insert txt)
         (setq buffer-read-only t))
      (cedille-adjust-info-window-size)
      (setq deactivate-mark nil)
      b)))
(make-variable-buffer-local
 (defvar cedille-mode-error-spans nil
   "List of all error spans."))
 
(make-variable-buffer-local
 (defvar cedille-mode-next-errors nil
   "Next spans with an error value."))

(make-variable-buffer-local
 (defvar cedille-mode-cur-error nil
   "The currently selected error span."))

(make-variable-buffer-local
 (defvar cedille-mode-prev-errors nil
   "Previously seen spans with an error value."))

(defun cedille-span-has-error-data(data)
  "Return t if the span has error data, and nil otherwise."
  (assoc 'error data))

(defun cedille-find-error-spans(spans)
  "Sets `cedille-mode-error-spans' to hold a list
of spans that have an error value."
  (when spans
    (let ((cur (car spans)))
      (when (cedille-span-has-error-data (se-span-data cur))
	(push cur cedille-mode-error-spans))
      (cedille-find-error-spans (cdr spans)))))
    
(defun cedille-mode-set-error-spans(response)
  "After loading spans from the backend tool, this hook will look for error
spans and set the variable `cedille-mode-error-spans'.  The input is ignored."
  (setq cedille-mode-next-errors nil)
  (setq cedille-mode-prev-errors nil)
  (setq cedille-mode-cur-error nil)
  (setq cedille-mode-error-spans nil)
  (cedille-find-error-spans se-mode-spans)
  (setq cedille-mode-error-spans (reverse cedille-mode-error-spans)) ; we are pushing the errors as we find them, so the list is reversed
  (setq cedille-mode-next-errors cedille-mode-error-spans)
)

(defun cedille-mode-any-errors()
  "Return t iff there are any errors."
  (or cedille-mode-next-errors cedille-mode-prev-errors cedille-mode-cur-error))

(defun cedille-mode-select-span(cur)
  "Select and highlight the given span."
   (se-mode-update-selected (se-find-span-path cur (se-mode-parse-tree)))
   (se-mode-mark-term cur)
   (push (pop se-mode-not-selected) se-mode-selected)
   (display-buffer (cedille-mode-inspect)))

(defun cedille-mode-select-first-error(selected-span)  
  "This should become the function that selects the first error in the selected span, but I haven't figured it out yet."
  (let ((first-error (car (delq nil (mapcar (lambda (x) (if (se-term-child-p x selected-span) x nil)) cedille-mode-error-spans)))))
    (if first-error
	(cedille-mode-select-error first-error)
        (message "No errors in selection")))) 

(defun cedille-mode-select-last-error(selected-span)  
  "This should become the function that selects the last error in the selected span, but I haven't figured it out yet."
  (let ((last-error (last (delq nil (mapcar (lambda (x) (if (se-term-child-p x selected-span) x nil)) cedille-mode-error-spans)))))
    (if last-error
	(cedille-mode-select-error last-error)
        (message "No errors in selection"))))

(defun cedille-mode-select-error(error-span)
	"Select the given error span and update cur-error, next-errors, and prev-errors"
	(cedille-mode-select-span error-span)
	(setq cedille-mode-next-errors (member error-span cedille-mode-error-spans))
	(setq cedille-mode-prev-errors (reverse (butlast cedille-mode-error-spans (safe-length cedille-mode-next-errors))))
	(setq cedille-mode-cur-error (pop cedille-mode-next-errors)))

(defun cedille-mode-next-error()
  "Select the next error from 'cedille-mode-next-errors', if any, and display the info buffer"
  (if (null cedille-mode-next-errors)
      (if (and (not (se-mode-selected)) cedille-mode-cur-error)
	  (cedille-mode-select-span cedille-mode-cur-error)
	  (message "No further errors"))
    (cedille-mode-select-error (car cedille-mode-next-errors))))

(defun cedille-mode-previous-error()
  "Select the previous error from 'cedille-mode-prev-erros', if any, and display the info buffer"
  (if (null cedille-mode-prev-errors)
      (if (and (not (se-mode-selected)) cedille-mode-cur-error)
	  (cedille-mode-select-span cedille-mode-cur-error)
	(message "No previous errors"))
    (cedille-mode-select-error (car cedille-mode-prev-errors))))


(defun cedille-mode-select-first-error-in-file()
  (interactive)
  (if (null cedille-mode-error-spans)
      (message "No errors.")
      (cedille-mode-select-error (car cedille-mode-error-spans))))

(defun cedille-mode-select-last-error-in-file()
  (interactive)
  (if (null cedille-mode-error-spans)
      (message "No errors.")
      (cedille-mode-select-error (last cedille-mode-error-spans))))

(defun cedille-mode-select-next-error()
  "Select the next error according to specifications, and display the info buffer."
  (interactive)
  (let ((selected-span (if (se-mode-selected) (se-first-span (se-mode-selected)) nil)))
    (cond
     ; if there are no errors, say so
     ((null cedille-mode-error-spans) (message "No errors."))
     ; if nothing is selected, go to the next error
     ((null selected-span) (cedille-mode-next-error))
     ; if the selected thing is the current error, go to the next error
     ((equal selected-span cedille-mode-cur-error) (cedille-mode-next-error))
     ; if the selected thing is another error, make it the current error
     ((member selected-span cedille-mode-error-spans) (cedille-mode-select-error selected-span))
     ; otherwise select the first error in the selected span (NOT IMPLEMENTED YET)
     (t (cedille-mode-select-first-error selected-span)))))

(defun cedille-mode-select-previous-error()
  "Select the previous error according to specifications, and display the info buffer."
  (interactive)
  (let ((selected-span (if (se-mode-selected) (se-first-span (se-mode-selected)) nil)))
    (cond
     ; if there are no errors, say so
     ((null cedille-mode-error-spans) (message "No errors."))
     ; if nothing is selected, go to the previous error
     ((null selected-span) (cedille-mode-previous-error))
     ; if the selected thing is the current error, go to previous error
     ((equal selected-span cedille-mode-cur-error) (cedille-mode-previous-error))
     ; if the selected thing is another error, make it the current error
     ((member selected-span cedille-mode-error-spans) (cedille-mode-select-error selected-span))
     ; otherwise select the last error in the selected span (NOT IMPLEMENTED YET)
     (t (cedille-mode-select-last-error selected-span)))))

(defun cedille-mode-select-next()
  "Selects the next sibling from the currently selected one in 
the parse tree, and updates the Cedille info buffer."
  (interactive)
  (se-mode-select-next)
  (cedille-mode-inspect))

(defun cedille-mode-select-previous()
  "Selects the previous sibling from the currently selected one in 
the parse tree, and updates the Cedille info buffer."
  (interactive)
  (se-mode-select-previous)
  (cedille-mode-inspect))

(defun cedille-mode-select-next-alt-test(x y)
  "Compares two spans x and y, testing whether x begins after y ends."
  (if (> (se-term-start y) (se-term-end x))
      t
      nil))

(defun cedille-mode-select-previous-alt-test(x y)
  (if (> (se-term-start x) (se-term-end y))
      t
      nil))

(defun cedille-mode-select-next-alt()
  "Selects the next sibling of the currently selected span, if one exists.
Otherwise, selects the first span beginning after the end of the current span,
Updates info buffer in either case"
  (interactive)
  (se-mode-set-spans)
  (unless (se-mode-select (se-mode-next))
    (let ((found (cl-find (se-mode-selected) se-mode-spans :test #'cedille-mode-select-next-alt-test)))
      (if (not found)
	  (message "No next span")
	  (progn (cedille-mode-select-span found)
	     (cedille-mode-inspect))))))

(defun cedille-mode-select-previous-alt()
  "Selects the previous sibling of the currently selected node;
otherwise selects first span that ends before the current span begins.
Updates info buffer in either case."
  (interactive)
  (se-mode-set-spans)
  (unless (se-mode-select (se-mode-previous))
    (let ((found (cl-find (se-mode-selected) se-mode-spans
			  :test #'cedille-mode-select-previous-alt-test
			  :from-end t)))
      (if (not found)
	  (message "No previous span")
	  (progn (cedille-mode-select-span found)
	     (cedille-mode-inspect))))))

(defun cedille-mode-select-parent()
  "Selects the parent of the currently selected node in 
the parse tree, and updates the Cedille info buffer."
  (interactive)
  (se-mode-expand-selected)
  (cedille-mode-inspect))

(defun cedille-mode-select-first-child()
  "Selects the first child of the lowest node in the parse tree
containing point, and updates the Cedille info buffer."
  (interactive)
  (se-mode-shrink-selected)
  (cedille-mode-inspect))

(defun cedille-mode-select-first()
  "Selects the first sibling of the currently selected node
in the parse tree, and updates the Cedille info buffer."
  (interactive)
  (se-mode-select-first)
  (cedille-mode-inspect))

(defun cedille-mode-select-last()
  "Selects the last sibling of the currently selected node
in the parse tree, and updates the Cedille info buffer."
  (interactive)
  (se-mode-select-last)
  (cedille-mode-inspect))

(defun cedille-mode-jump ()
  "Jumps to a location associated with the selected node"
  (interactive)
  (if se-mode-selected
     (let* ((b (cedille-info-buffer))
            (d (se-term-data (se-mode-selected)))
            (lp (assoc 'location d)))
        (if lp 
            (let* ((l (cdr lp))
                   (ls (split-string l " - "))
                   (f (car ls))
                   (n (string-to-number (cadr ls)))
                   (b (find-file f)))
              (with-current-buffer b (goto-char n) (se-navigation-mode)))
            (message "No location at this node")))
    (message "No node selected"))
  ;;; If the mark is active, we are jumping within the buffer. This prevents
  ;;; a region from being selected.
  (if mark-active
      (progn
	(exchange-point-and-mark 1)
	(set-mark-command 1))))


(defun cedille-mode-toggle-info()
  "Shows or hides the Cedille info buffer."
  (interactive)
  (let* ((b (cedille-info-buffer))
         (w (get-buffer-window b)))
    (if w (delete-window w) (display-buffer b) (cedille-adjust-info-window-size))))

(defun cedille-mode-quit()
  "Quit Cedille navigation mode"
  (interactive)
  (se-mode-clear-selected)
  (se-navigation-mode-quit)
  (setq se-mode-parse-tree nil))

; se-navi-define-key maintains an association with the major mode,
; so that different major modes using se-navi-define-key can have
; separate keymaps.
(defun cedille-modify-keymap()
  (se-navi-define-key 'cedille-mode (kbd "f") #'cedille-mode-select-next)
  (se-navi-define-key 'cedille-mode (kbd "F") #'cedille-mode-select-next-alt)
  (se-navi-define-key 'cedille-mode (kbd "b") #'cedille-mode-select-previous)
  (se-navi-define-key 'cedille-mode (kbd "B") #'cedille-mode-select-previous-alt)
  (se-navi-define-key 'cedille-mode (kbd "p") #'cedille-mode-select-parent)
  (se-navi-define-key 'cedille-mode (kbd "n") #'cedille-mode-select-first-child)
  (se-navi-define-key 'cedille-mode (kbd "g") #'se-mode-clear-selected)
  (se-navi-define-key 'cedille-mode (kbd "q") #'cedille-mode-quit)
  (se-navi-define-key 'cedille-mode (kbd "M-s") #'cedille-mode-quit)
  (se-navi-define-key 'cedille-mode (kbd "C-g") #'cedille-mode-quit)
  (se-navi-define-key 'cedille-mode (kbd "e") #'cedille-mode-select-last)
  (se-navi-define-key 'cedille-mode (kbd "a") #'cedille-mode-select-first)
  (se-navi-define-key 'cedille-mode (kbd "i") #'cedille-mode-toggle-info)
  (se-navi-define-key 'cedille-mode (kbd "j") #'cedille-mode-jump)
  (se-navi-define-key 'cedille-mode (kbd "r") #'cedille-mode-select-next-error)
  (se-navi-define-key 'cedille-mode (kbd "R") #'cedille-mode-select-previous-error)
  (se-navi-define-key 'cedille-mode (kbd "t") #'cedille-mode-select-first-error-in-file)
  (se-navi-define-key 'cedille-mode (kbd "T") #'cedille-mode-select-last-error-in-file)
  (se-navi-define-key 'cedille-mode (kbd "s") nil)
  (se-navi-define-key 'cedille-mode (kbd "C-h") #'se-highlight)
)

(cedille-modify-keymap)

(se-create-mode "cedille" nil
  "Major mode for Cedille files."

  (setq-local comment-start "%")
  
  (se-inf-start
   (or (get-buffer-process "*cedille-mode*") ;; reuse if existing process
       (start-process "cedille-mode" "*cedille-mode*" cedille-program-name "+RTS" "-K1000000000" "-RTS")))

  (set-input-method "Cedille")
)

(add-hook 'se-inf-response-hook 'cedille-mode-set-error-spans t)
(add-hook 'se-inf-init-spans-hook 'cedille-mode-initialize-spans t)
(add-hook 'se-inf-init-spans-hook 'se-highlight t)

(modify-coding-system-alist 'file "\\.ced\\'" 'utf-8)

(quail-define-package "Cedille" "UTF-8" "δ" t ; guidance
		      "Cedille input method."
		      nil nil nil nil nil nil t) ; maximum-shortest

(mapc (lambda (pair) (quail-defrule (car pair) (cadr pair) "Cedille"))
	'(("\\l" "λ") ("\\L" "Λ") ("\\>" "→") ("\\r" "→") ("\\a" "∀") ("\\B" "□") ("\\P" "Π") 
          ("\\s" "★") ("\\S" "☆") ("\\." "·") ("\\f" "⇐") ("\\<" "⇐") ("\\u" "↑") ("\\p" "π")
          ("\\h" "●") ("\\k" "𝒌") ("\\i" "ι") ("\\=" "≃") ("\\d" "δ") 
          ("\\b" "β") ("\\e" "ε") ("\\R" "ρ") ("\\y" "ς") ("\\t" "θ") ("\\x" "χ")

          ("\\rho" "ρ") ("\\theta" "θ") ("\\epsilon" "ε") ; add some more of these
 ))

(provide 'cedille-mode)
;;; cedille-mode.el ends here

