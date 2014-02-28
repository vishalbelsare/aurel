;;; aurel.el --- Search, get info and download AUR packages

;; Copyright (C) 2014 Alex Kost

;; Author: Alex Kost <alezost@gmail.com>
;; Created: 6 Feb 2014
;; Version: 0.3
;; URL: https://github.com/alezost/aurel
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The package provides an interface for searching, getting information
;; and downloading packages from the Arch User Repository (AUR)
;; <https://aur.archlinux.org/>.

;; To manually install the package, add the following to your init-file:
;;
;;   (add-to-list 'load-path "/path/to/aurel-dir")
;;   (autoload 'aurel-package-info "aurel" nil t)
;;   (autoload 'aurel-package-search "aurel" nil t)
;;   (autoload 'aurel-maintainer-search "aurel" nil t)

;; Also set a directory where downloaded packages will be put:
;;
;;   (setq aurel-download-directory "~/aur")

;; To search for packages, use `aurel-package-search' or
;; `aurel-maintainer-search' commands.  If you know the name of a
;; package, use `aurel-package-info' command.

;; Information about the packages is represented in a list-like buffer
;; similar to a buffer containing emacs packages.  To get more info
;; about a package, press "RET" on a package line.  To download a
;; package, press "d" (don't forget to set `aurel-download-directory'
;; before).

;; After receiving information about the packages, pacman is called to
;; find what packages are installed.  To disable that, set
;; `aurel-installed-packages-check' to nil.

;; For full description, see <https://github.com/alezost/aurel>.

;;; Code:

(require 'url-expand)
(require 'url-handlers)
(require 'json)
(require 'tabulated-list)
(require 'cl-macs)

(defgroup aurel nil
  "Search and download AUR (Arch User Repository) packages."
  :group 'applications)

(defcustom aurel-empty-string "-"
  "String used for empty (or none) values of package parameters."
  :type 'string
  :group 'aurel)

(defcustom aurel-outdated-string "Yes"
  "String used for outdated parameter if a package is out of date."
  :type 'string
  :group 'aurel)

(defcustom aurel-not-outdated-string "No"
  "String used for outdated parameter if a package is not out of date."
  :type 'string
  :group 'aurel)

(defcustom aurel-date-format "%Y-%m-%d %T"
  "Time format used to represent submit and last dates of a package.
For information about time formats, see `format-time-string'."
  :type 'string
  :group 'aurel)

(defun aurel-get-string (val &optional face)
  "Return string from VAL.
If VAL is nil, return `aurel-empty-string'.
Otherwise, if VAL is not string, use `prin1-to-string'.
If FACE is specified, propertize returned string with this FACE."
  (if val
      (progn
        (or (stringp val)
            (setq val (prin1-to-string val)))
        (if face
            (propertize val 'face face)
          val))
    aurel-empty-string))


;;; Interacting with AUR server

(defvar aurel-base-url "https://aur.archlinux.org/"
  "Root URL of the AUR service.")

;; Avoid compilation warning about `url-http-response-status'
(defvar url-http-response-status)

(defun aurel-receive-parse-info (url)
  "Return received output from URL processed with `json-read'."
  (let ((buf (url-retrieve-synchronously url)))
    (with-current-buffer buf
      (if (or (null (numberp url-http-response-status))
              (> url-http-response-status 299))
          (error "Error during request: %s" url-http-response-status))
      (goto-char (point-min))
      (re-search-forward "^{") ;; is there a better way?
      (beginning-of-line)
      (let ((json-key-type 'string)
            (json-array-type 'list)
            (json-object-type 'alist))
        (json-read)))))

(defun aurel-get-aur-packages-info (url)
  "Return information about the packages from URL.
Output from URL should be a json data.  It is parsed with
`json-read'.
Returning value is alist of AUR package parameters (strings from
`aurel-aur-param-alist') and their values."
  (let* ((full-info (aurel-receive-parse-info url))
         (type      (cdr (assoc "type" full-info)))
         (count     (cdr (assoc "resultcount" full-info)))
         (results   (cdr (assoc "results" full-info))))
    (cond
     ((string= type "error")
      (error "%s" results))
     ((= count 0)
      nil)
     (t
      (when (string= type "info")
        (setq results (list results)))
      results))))


;;; Interacting with pacman

(defcustom aurel-pacman-program "pacman"
  "Absolute or relative name of `pacman' program."
  :type 'string
  :group 'aurel)

(defcustom aurel-installed-packages-check t
  "If non-nil, check if the found packages are installed.
If nil, searching works faster, because `aurel-pacman-program' is not
called, but it stays unknown if a package is installed or not."
  :type 'boolean
  :group 'aurel)

(defvar aurel-pacman-buffer-name " *aurel-pacman*"
  "Name of the buffer used internally for pacman output.")

(defvar aurel-pacman-info-line-re
  (rx line-start
      (group (+? (any word " ")))
      (+ " ") ":" (+ " ")
      (group (+ any))
      line-end)
  "Regexp matching a line of pacman query info output.
Contain 2 parenthesized groups: parameter name and its value.")

(defun aurel-call-pacman (&optional buffer &rest args)
  "Call `aurel-pacman-program' with arguments ARGS.
Insert output in BUFFER.  If it is nil, use `aurel-pacman-buffer-name'.
Return numeric exit status."
  (let ((pacman (executable-find aurel-pacman-program)))
    (or pacman
        (error (concat "Couldn't find '%s'.\n"
                       "Set aurel-pacman-program to a proper value")
               aurel-pacman-program))
    (with-current-buffer
        (or buffer (get-buffer-create aurel-pacman-buffer-name))
      (erase-buffer)
      (apply 'call-process pacman nil t nil args))))

(defun aurel-get-installed-packages-info (&rest names)
  "Return information about installed packages NAMES.
Each name from NAMES should be a string (a name of a package).
Returning value is a list of alists with installed package
parameters (strings from `aurel-installed-param-alist') and their
values."
  (let ((buf (get-buffer-create aurel-pacman-buffer-name)))
    (apply 'aurel-call-pacman buf "--query" "--info" names)
    (aurel-pacman-query-buffer-parse buf)))

(defun aurel-pacman-query-buffer-parse (&optional buffer)
  "Parse BUFFER with packages info.
BUFFER should contain an output returned by 'pacman -Qi' command.
If BUFFER is nil, use `aurel-pacman-buffer-name'.
Return list of alists with parameter names and values."
  (with-current-buffer
      (or buffer (get-buffer-create aurel-pacman-buffer-name))
    (let ((max (point-max))
          (beg (point-min))
          end info)
      ;; Packages info are separated with empty lines, search for those
      ;; till the end of buffer
      (cl-loop
       do (progn
            (goto-char beg)
            (setq end (re-search-forward "^\n" nil t))
            (and end
                 (setq info (aurel-pacman-query-region-parse beg end)
                       beg end)))
       while end
       if info collect info))))

(defun aurel-pacman-query-region-parse (beg end)
  "Parse text (package info) in current buffer from BEG to END.
Parsing region should be an output for one package returned by
'pacman -Qi' command.
Return alist with parameter names and values."
  ;; TODO parse multiline parameters
  (goto-char beg)
  (let (point)
    (cl-loop
     do (setq point (re-search-forward
                     aurel-pacman-info-line-re end t))
     while point
     collect (cons (match-string 1) (match-string 2)))))


;;; Package parameters

(defvar aurel-aur-param-alist
  '((pkg-url     . "URLPath")
    (home-url    . "URL")
    (last-date   . "LastModified")
    (first-date  . "FirstSubmitted")
    (outdated    . "OutOfDate")
    (votes       . "NumVotes")
    (license     . "License")
    (description . "Description")
    (category    . "CategoryID")
    (version     . "Version")
    (name        . "Name")
    (id          . "ID")
    (maintainer  . "Maintainer"))
  "Association list of symbols and names of package info parameters.
Car of each assoc is a symbol used in code of this package.
Cdr - is a parameter name (string) returned by the AUR server.")

(defvar aurel-pacman-param-alist
  '((installed-name    . "Name")
    (installed-version . "Version")
    (architecture      . "Architecture")
    (provides          . "Provides")
    (depends           . "Depends On")
    (required          . "Required By")
    (optional-for      . "Optional For")
    (conflicts         . "Conflicts With")
    (replaces          . "Replaces")
    (installed-size    . "Installed Size")
    (packager          . "Packager")
    (build-date        . "Build Date")
    (install-date      . "Install Date"))
  "Association list of symbols and names of package info parameters.
Car of each assoc is a symbol used in code of this package.
Cdr - is a parameter name (string) returned by pacman.")

(defvar aurel-param-description-alist
  '((pkg-url           . "Download URL")
    (home-url          . "Home Page")
    (aur-url           . "AUR Page")
    (last-date         . "Last Modified")
    (first-date        . "Submitted")
    (outdated          . "Out Of Date")
    (votes             . "Votes")
    (license           . "License")
    (description       . "Description")
    (category          . "Category")
    (version           . "Version")
    (name              . "Name")
    (id                . "ID")
    (maintainer        . "Maintainer")
    (installed-name    . "Name")
    (installed-version . "Version")
    (architecture      . "Architecture")
    (provides          . "Provides")
    (depends           . "Depends On")
    (required          . "Required By")
    (optional-for      . "Optional For")
    (conflicts         . "Conflicts With")
    (replaces          . "Replaces")
    (installed-size    . "Size")
    (packager          . "Packager")
    (build-date        . "Build Date")
    (install-date      . "Install Date"))
  "Association list of symbols and descriptions of parameters.
Descriptions are used for displaying package information.
Symbols are either from `aurel-aur-param-alist', from
`aurel-pacman-param-alist' or are added by filter functions.  See
`aurel-apply-filters' for details.")

(defun aurel-get-aur-param-name (param-symbol)
  "Return a name (string) of a parameter.
PARAM-SYMBOL is a symbol from `aurel-aur-param-alist'."
  (cdr (assoc param-symbol aurel-aur-param-alist)))

(defun aurel-get-aur-param-symbol (param-name)
  "Return a symbol name of a parameter.
PARAM-NAME is a string from `aurel-aur-param-alist'."
  (car (rassoc param-name aurel-aur-param-alist)))

(defun aurel-get-pacman-param-name (param-symbol)
  "Return a name (string) of a parameter.
PARAM-SYMBOL is a symbol from `aurel-pacman-param-alist'."
  (cdr (assoc param-symbol aurel-pacman-param-alist)))

(defun aurel-get-pacman-param-symbol (param-name)
  "Return a symbol name of a parameter.
PARAM-NAME is a string from `aurel-pacman-param-alist'."
  (car (rassoc param-name aurel-pacman-param-alist)))

(defun aurel-get-param-description (param-symbol)
  "Return a description of a parameter PARAM-SYMBOL."
  (let ((desc (cdr (assoc param-symbol
                          aurel-param-description-alist))))
    (or desc
        (progn
          (setq desc (symbol-name param-symbol))
          (message "Couldn't find '%s' in aurel-param-description-alist."
                   desc)
          desc))))

(defun aurel-get-param-val (param info)
  "Return a value of a parameter PARAM from a package INFO."
  (cdr (assoc param info)))


;;; Filters for processing package info

(defvar aurel-categories
  [nil "None" "daemons" "devel" "editors"
       "emulators" "games" "gnome" "i18n" "kde" "lib"
       "modules" "multimedia" "network" "office"
       "science" "system" "x11" "xfce" "kernels" "fonts"]
  "Vector of package categories.
Index of an element is a category ID.")

(defvar aurel-filter-params nil
  "List of parameters (symbols), that should match specified strings.
Used in `aurel-filter-contains-every-string'.")

(defvar aurel-filter-strings nil
  "List of strings, a package info should match.
Used in `aurel-filter-contains-every-string'.")

(defvar aurel-aur-filters
  '(aurel-aur-filter-intern aurel-filter-contains-every-string
    aurel-aur-filter-date
    aurel-filter-outdated aurel-filter-category
    aurel-filter-pkg-url aurel-filter-aur-url)
  "List of filter functions applied to a package info got from AUR.

Each filter function should accept a single argument - info alist
with package parameters and should return info alist or
nil (which means: ignore this package info).  Functions may
modify associations or add the new ones to the alist.  In the
latter case you might want to add descriptions of the added
symbols into `aurel-param-description-alist'.

`aurel-aur-filter-intern' should be the first symbol in the list as
other filters use symbols for working with info parameters (see
`aurel-aur-param-alist').

For more information, see `aurel-receive-packages-info'.")

(defvar aurel-pacman-filters
  '(aurel-pacman-filter-intern aurel-pacman-filter-date)
"List of filter functions applied to a package info got from pacman.

`aurel-pacman-filter-intern' should be the first symbol in the list as
other filters use symbols for working with info parameters (see
`aurel-pacman-param-alist').

For more information, see `aurel-aur-filters' and
`aurel-receive-packages-info'.")

(defvar aurel-final-filters
  '(aurel-filter-empty)
  "List of filter functions applied to a package info.
For more information, see `aurel-receive-packages-info'.")

(defun aurel-apply-filters (info filters)
  "Apply functions from FILTERS list to a package INFO.

INFO is alist with package parameters.  It is passed as an
argument to the first function from FILTERS, the returned result
is passed to the second function from that list and so on.

Return filtered info (result of the last filter).  Return nil, if
one of the FILTERS returns nil (do not call the rest filters)."
  (cl-loop for fun in filters
           do (setq info (funcall fun info))
           while info
           finally return info))

(defun aurel-filter-intern (info param-fun &optional warning)
  "Replace names of parameters with symbols in a package INFO.
INFO is alist of parameter names (strings) and values.
PARAM-FUN is a function for getting parameter internal symbol by
its name (string).
If WARNING is non-nil, show a message if unknown parameter is found.
Return modified info."
  (delq nil
        (mapcar
         (lambda (param)
           (let* ((param-name (car param))
                  (param-symbol (funcall param-fun param-name))
                  (param-val (cdr param)))
             (if param-symbol
                 (cons param-symbol param-val)
               (and warning
                    (message "Warning: unknown parameter '%s'. It will be omitted."
                             param-name))
               nil)))
         info)))

(defun aurel-aur-filter-intern (info)
  "Replace names of parameters with symbols in a package INFO.
INFO is alist of parameter names (strings) from
`aurel-aur-param-alist' and their values.
Return modified info."
  (aurel-filter-intern info 'aurel-get-aur-param-symbol t))

(defun aurel-pacman-filter-intern (info)
  "Replace names of parameters with symbols in a package INFO.
INFO is alist of parameter names (strings) from
`aurel-pacman-param-alist' and their values.
Return modified info."
  (aurel-filter-intern info 'aurel-get-pacman-param-symbol))

(defun aurel-filter-contains-every-string (info)
  "Check if a package INFO contains all necessary strings.

Return INFO, if values of parameters from `aurel-filter-params'
contain all strings from `aurel-filter-strings', otherwise return nil.

Pass the check (return INFO), if `aurel-filter-strings' or
`aurel-filter-params' is nil."
  (when (or (null aurel-filter-params)
            (null aurel-filter-strings)
            (let ((str (mapconcat (lambda (param)
                                    (aurel-get-param-val param info))
                                  aurel-filter-params
                                  "\n")))
              (cl-every (lambda (substr)
                          (string-match-p (regexp-quote substr) str))
                        aurel-filter-strings)))
    info))

(defun aurel-filter-empty (info)
  "Replace nil in parameter values with `aurel-empty-string' in a package INFO.
INFO is alist of parameter names (strings) and values.
Return modified info."
  (dolist (param info info)
    (let ((val (cdr param)))
      (when (or (null val)
                (equal val "None"))
        (setcdr param aurel-empty-string)))))

(defun aurel-filter-date (info fun &rest params)
  "Format date parameters PARAMS of a package INFO.
INFO is alist of parameter symbols and values.
FUN is a function taking parameter value as an argument and
returning time value.  Use `aurel-date-format' for formatting.
Return modified info."
  (dolist (param info info)
    (let ((param-name (car param))
          (param-val  (cdr param)))
      (when (memq param-name params)
        (setcdr param
                (format-time-string aurel-date-format
                                    (funcall fun param-val)))))))

(defun aurel-aur-filter-date (info)
  "Format date parameters of a package INFO with `aurel-date-format'.
Formatted parameters: `first-date', `last-date'.
INFO is alist of parameter symbols and values.
Return modified info."
  (aurel-filter-date info 'seconds-to-time 'first-date 'last-date))

(defun aurel-pacman-filter-date (info)
  "Format date parameters of a package INFO with `aurel-date-format'.
Formatted parameters: `install-date', `build-date'.
INFO is alist of parameter symbols and values.
Return modified info."
  (aurel-filter-date info 'date-to-time 'install-date 'build-date))

(defun aurel-filter-outdated (info)
  "Change `outdated' parameter of a package INFO.
Replace 1/0 with `aurel-outdated-string'/`aurel-not-outdated-string'.
INFO is alist of parameter symbols and values.
Return modified info."
  (let ((param (assoc 'outdated info)))
    (setcdr param
            (if (= 0 (cdr param))
                aurel-not-outdated-string
              aurel-outdated-string)))
  info)

(defun aurel-filter-category (info)
  "Replace category ID with category name in a package INFO.
INFO is alist of parameter symbols and values.
Return modified info."
  (let ((param (assoc 'category info)))
    (setcdr param (aref aurel-categories (cdr param))))
  info)

(defun aurel-filter-pkg-url (info)
  "Update `pkg-url' parameter in a package INFO.
INFO is alist of parameter symbols and values.
Return modified info."
  (let ((param (assoc 'pkg-url info)))
    (setcdr param (url-expand-file-name (cdr param) aurel-base-url)))
  info)

(defun aurel-filter-aur-url (info)
  "Add `aur-url' parameter to a package INFO.
INFO is alist of parameter symbols and values.
Return modified info."
  (add-to-list
   'info
   (cons 'aur-url
         (url-expand-file-name
          (concat "packages/" (aurel-get-param-val 'name info))
          aurel-base-url))))


;;; Backend

(defun aurel-receive-packages-info (url)
  "Return information about the packages from URL.

Information is received with `aurel-get-aur-packages-info', then
it is passed through `aurel-aur-filters' with
`aurel-apply-filters'.  If `aurel-installed-packages-check' is
non-nil, additional information about installed packages is
received with `aurel-get-installed-packages-info' and is passed
through `aurel-installed-filters'.  Finally packages info is passed
through `aurel-final-filters'.

Returning value is alist, each element of which has a form:

  (ID . INFO)

ID is a package id (number).
INFO is alist of package parameters and values (see `aurel-info')."
  ;; To speed-up the process, pacman should be called once with the
  ;; names of found packages (instead of calling it for each name).  So
  ;; we need to know the names at first, that's why we don't use a
  ;; single filters variable: at first we filter info received from AUR,
  ;; then we add information about installed packages from pacman and
  ;; finally filter the whole info.
  (let (aur-info-list aur-info-alist
        pac-info-list pac-info-alist
        info-list)
    ;; Receive and process information from AUR server
    (setq aur-info-list  (aurel-get-aur-packages-info url)
          aur-info-alist (aurel-get-filtered-alist
                          aur-info-list aurel-aur-filters 'name))
    ;; Receive and process information from pacman
    (when aurel-installed-packages-check
      (setq pac-info-list  (apply 'aurel-get-installed-packages-info
                                  (mapcar #'car aur-info-alist))
            pac-info-alist (aurel-get-filtered-alist
                            pac-info-list
                            aurel-pacman-filters
                            'installed-name)))
    ;; Join info and do final processing
    (setq info-list
          (mapcar (lambda (aur-info-assoc)
                    (let* ((name (car aur-info-assoc))
                           (pac-info-assoc (assoc name pac-info-alist)))
                      (append (cdr aur-info-assoc)
                              (cdr pac-info-assoc))))
                  aur-info-alist))
    (aurel-get-filtered-alist info-list aurel-final-filters 'id)))

(defun aurel-get-filtered-alist (info-list filters param)
  "Return alist with filtered packages info.
INFO-LIST is a list of packages info.  Each info is passed through
FILTERS with `aurel-apply-filters'.

Each association of a returned value has a form:

  (PARAM-VAL . INFO)

PARAM-VAL is a value of a parameter PARAM.
INFO is a filtered package info."
  (delq nil                             ; ignore filtered (empty) info
        (mapcar (lambda (info)
                  (let ((info (aurel-apply-filters info filters)))
                    (and info
                         (cons (aurel-get-param-val param info) info))))
                info-list)))


;;; History

(defvar-local aurel-history-stack-item nil
  "Current item of the history.
A list of the form (FUNCTION [ARGS ...]).
The item is used by calling (apply FUNCTION ARGS).")
(put 'aurel-history-stack-item 'permanent-local t)

(defvar-local aurel-history-back-stack nil
  "Stack (list) of visited items.
Each element of the list has a form of `aurel-history-stack-item'.")
(put 'aurel-history-back-stack 'permanent-local t)

(defvar-local aurel-history-forward-stack nil
  "Stack (list) of items visited with `aurel-history-back'.
Each element of the list has a form of `aurel-history-stack-item'.")
(put 'aurel-history-forward-stack 'permanent-local t)

(defvar aurel-history-size 0
  "Maximum number of items saved in history.
If 0, the history is disabled.")

(defun aurel-history-add (item)
  "Add ITEM to history."
  (and aurel-history-stack-item
       (push aurel-history-stack-item aurel-history-back-stack))
  (setq aurel-history-forward-stack nil
        aurel-history-stack-item item)
  (when (>= (length aurel-history-back-stack)
            aurel-history-size)
    (setq aurel-history-back-stack
          (cl-loop for elt in aurel-history-back-stack
                   for i from 1 to aurel-history-size
                   collect elt))))

(defun aurel-history-goto (item)
  "Go to the ITEM of history.
ITEM should have the form of `aurel-history-stack-item'."
  (or (listp item)
      (error "Wrong value of history element"))
  (setq aurel-history-stack-item item)
  (apply (car item) (cdr item)))

(defun aurel-history-back ()
  "Go back to the previous element of history in the current buffer."
  (interactive)
  (or aurel-history-back-stack
      (user-error "No previous element in history"))
  (push aurel-history-stack-item aurel-history-forward-stack)
  (aurel-history-goto (pop aurel-history-back-stack)))

(defun aurel-history-forward ()
  "Go forward to the next element of history in the current buffer."
  (interactive)
  (or aurel-history-forward-stack
      (user-error "No next element in history"))
  (push aurel-history-stack-item aurel-history-back-stack)
  (aurel-history-goto (pop aurel-history-forward-stack)))


;;; Downloading

(defcustom aurel-download-directory "/tmp"
  "Default directory for downloading AUR packages."
  :type 'directory
  :group 'aurel)

(defcustom aurel-directory-prompt "Download to: "
  "Default directory prompt for downloading AUR packages."
  :type 'string
  :group 'aurel)

(defun aurel-download (url dir)
  "Download AUR package from URL to a directory DIR.
Return a path to the downloaded file."
  ;; Is there a simpler way to download a file?
  (let ((file-name-handler-alist
         (cons (cons url-handler-regexp 'url-file-handler)
               file-name-handler-alist)))
    (with-temp-buffer
      (insert-file-contents-literally url)
      (let ((file (expand-file-name (url-file-nondirectory url) dir)))
        (write-file file)
        file))))

;; Code for working with `tar-mode' came from `package-untar-buffer'

;; Avoid compilation warnings about tar functions and variables
(defvar tar-parse-info)
(defvar tar-data-buffer)
(declare-function tar-data-swapped-p "tar-mode" ())
(declare-function tar-untar-buffer "tar-mode" ())
(declare-function tar-header-name "tar-mode" (tar-header) t)
(declare-function tar-header-link-type "tar-mode" (tar-header) t)

(defun aurel-download-unpack (url dir)
  "Download AUR package from URL and unpack it into a directory DIR.

Use `tar-untar-buffer' from Tar mode.  All files should be placed
in one directory; otherwise, signal an error.

Return a path to the unpacked directory."
  (let ((file-name-handler-alist
         (cons (cons url-handler-regexp 'url-file-handler)
               file-name-handler-alist)))
    (with-temp-buffer
      (insert-file-contents url)
      (setq default-directory dir)
      (let ((file (expand-file-name (url-file-nondirectory url) dir)))
        (write-file file))
      (tar-mode)
      ;; Make sure the first header is a dir and all files are
      ;; placed in it (is it correct?)
      (let* ((tar-car-data (car tar-parse-info))
             (tar-dir (tar-header-name tar-car-data))
             (tar-dir-re (regexp-quote tar-dir)))
        (or (eq (tar-header-link-type tar-car-data) 5)
            (error "The first entry '%s' in tar file is not a directory"
                   tar-dir))
        (dolist (tar-data (cdr tar-parse-info))
          (or (string-match tar-dir-re (tar-header-name tar-data))
              (error "Not all files are extracted into directory '%s'"
                     tar-dir)))
        (tar-untar-buffer)
        (expand-file-name tar-dir dir)))))

(defun aurel-download-unpack-dired (url dir)
  "Download and unpack AUR package, and open the unpacked directory.
For the meaning of URL and DIR, see `aurel-download-unpack'."
  (dired (aurel-download-unpack url dir)))

(defun aurel-download-unpack-pkgbuild (url dir)
  "Download and unpack AUR package, and open PKGBUILD file.
For the meaning of URL and DIR, see `aurel-download-unpack'."
  (let* ((pkg-dir (aurel-download-unpack url dir))
         (file (expand-file-name "PKGBUILD" pkg-dir)))
    (if (file-exists-p file)
        (find-file file)
      (error "File '%s' doesn't exist" file))))

;; Avoid compilation warning about `eshell/cd'
(declare-function eshell/cd "em-dirs" (&rest args))

(defun aurel-download-unpack-eshell (url dir)
  "Download and unpack AUR package, switch to eshell.
For the meaning of URL and DIR, see `aurel-download-unpack'."
  (let ((pkg-dir (aurel-download-unpack url dir)))
    (eshell)
    (eshell/cd pkg-dir)))


;;; Defining URL

(defun aurel-get-rpc-url (type arg)
  "Return URL for getting info about AUR packages.
TYPE is the name of an allowed method.
ARG is the argument to the call."
  (url-expand-file-name
   (format "rpc.php?type=%s&arg=%s"
           (url-hexify-string type)
           (url-hexify-string arg))
   aurel-base-url))

(defun aurel-get-package-info-url (package)
  "Return URL for getting info about a PACKAGE.
PACKAGE can be either a string (name) or a number (ID)."
  (aurel-get-rpc-url "info"
                     (if (numberp package)
                         (number-to-string package)
                       package)))

(defun aurel-get-package-search-url (str)
  "Return URL for searching a package by string STR."
  (aurel-get-rpc-url "search" str))

(defun aurel-get-maintainer-search-url (str)
  "Return URL for searching a maintainer by string STR."
  (aurel-get-rpc-url "msearch" str))


;;; UI

(defcustom aurel-list-single-package nil
  "If non-nil, list a package even if it is the one matching result.
If nil, show a single matching package in info buffer."
  :type 'boolean
  :group 'aurel)

(defvar aurel-package-info-history nil
  "A history list for `aurel-package-info'.")

(defvar aurel-package-search-history nil
  "A history list for `aurel-package-search'.")

(defvar aurel-maintainer-search-history nil
  "A history list for `aurel-maintainer-search'.")

;;;###autoload
(defun aurel-package-info (name-or-id &optional arg)
  "Display information about AUR package NAME-OR-ID.
NAME-OR-ID may be a string or a number.
The buffer for showing results is defined by `aurel-info-buffer-name'.
With prefix (if ARG is non-nil), show results in a new info buffer."
  (interactive
   (list (read-string "Name or ID: "
                      nil 'aurel-package-info-history)
         current-prefix-arg))
  (when (numberp name-or-id)
    (setq name-or-id (number-to-string name-or-id)))
  (let ((packages (aurel-receive-packages-info
                   (aurel-get-package-info-url name-or-id))))
    (if packages
        (aurel-info-show (cdar packages)
                         (aurel-info-get-buffer-name arg))
      (message "Package %s not found." name-or-id))))

;;;###autoload
(defun aurel-package-search (str &optional arg)
  "Search for AUR packages matching a string STR.

STR can be a string of multiple words separated by spaces.  To
search for a string containing spaces, quote it with double
quotes.  For example, the following search is allowed:

  \"python library\" plot

The buffer for showing results is defined by
`aurel-list-buffer-name'.  With prefix (if ARG is non-nil), show
results in a new buffer."
  (interactive
   (list (read-string "Search by name/description: "
                      nil 'aurel-package-search-history)
         current-prefix-arg))
  ;; A hack for searching by multiple strings: the actual server search
  ;; is done by the biggest string and the rest strings are searched in
  ;; the results returned by the server
  (let* ((strings
          ;; sort to search by the biggest (first) string
          (sort (split-string-and-unquote str)
                (lambda (a b)
                  (> (length a) (length b)))))
         (packages
          (let ((aurel-filter-params '(name description))
                (aurel-filter-strings (cdr strings)))
            (aurel-receive-packages-info
             (aurel-get-package-search-url (car strings))))))
    (cond
     ((null packages)
      (message "No packages matching '%s'." str))
     ((and (null (cdr packages))
           (null aurel-list-single-package))
      (aurel-info-show (cdar packages)
                       (aurel-info-get-buffer-name arg))
      (message "A single package matching '%s' found." str))
     (t
      (aurel-list-show packages
                       (aurel-list-get-buffer-name arg))))))

;;;###autoload
(defun aurel-maintainer-search (name &optional arg)
  "Search for AUR packages by maintainer NAME.
The buffer for showing results is defined by `aurel-list-buffer-name'.
With prefix (if ARG is non-nil), show results in a new buffer."
  (interactive
   (list (read-string "Search by maintainer: "
                      nil 'aurel-maintainer-search-history)
         current-prefix-arg))
  (let ((packages (aurel-receive-packages-info
                   (aurel-get-maintainer-search-url name))))
    (cond
     ((null packages)
      (message "No packages matching maintainer '%s'." name))
     ((and (null (cdr packages))
           (null aurel-list-single-package))
      (aurel-info-show (cdar packages)
                       (aurel-info-get-buffer-name arg))
      (message "A single package by maintainer '%s' found." name))
     (t
      (aurel-list-show packages
                       (aurel-list-get-buffer-name arg))))))


;;; Package list

(defgroup aurel-list nil
  "Buffer with a list of AUR packages."
  :group 'aurel)

(defcustom aurel-list-buffer-name "*AUR Package List*"
  "Default name of the buffer with a list of AUR packages."
  :type 'string
  :group 'aurel-list)

(defcustom aurel-list-download-function 'aurel-download-unpack
  "Function used for downloading AUR package from package list buffer.
It should accept 2 arguments: URL of a downloading file and a
destination directory."
  :type 'function
  :group 'aurel-list)

(defcustom aurel-list-history-size 10
  "Maximum number of items saved in history of package list buffer.
If 0, the history is disabled."
  :type 'integer
  :group 'aurel-list)

(defvar aurel-list-column-name-alist
  '((installed-version . "Installed"))
  "Alist of parameter names used as titles for columns.
Each association is a cons of parameter symbol and column name.
If no parameter is not found in this alist, the value from
`aurel-param-description-alist' is used for a column name.")

(defvar aurel-list nil
  "Alist with packages info.

Car of each assoc is a package ID (number).
Cdr - is alist of package info of the form of `aurel-info'.")

(defvar aurel-list-column-format
  '((name 25 t)
    (version 15 nil)
    (installed-version 15 t)
    (description 30 nil))
  "List specifying columns used in the buffer with a list of packages.
Each element of the list should have the form (NAME WIDTH SORT . PROPS).
NAME is a parameter symbol from `aurel-param-description-alist'.
For the meaning of WIDTH, SORT and PROPS, see `tabulated-list-format'.")

(defvar aurel-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map "\C-m" 'aurel-list-describe-package)
    (define-key map "d" 'aurel-list-download-package)
    (define-key map "l" 'aurel-history-back)
    (define-key map "r" 'aurel-history-forward)
    map)
  "Keymap for `aurel-list-mode'.")

(defun aurel-list-get-buffer-name (&optional unique)
  "Return a name of a list buffer.
If UNIQUE is non-nil, make the name unique."
  (if unique
      (generate-new-buffer aurel-list-buffer-name)
    aurel-list-buffer-name))

(define-derived-mode aurel-list-mode
  tabulated-list-mode "AURel-list"
  "Major mode for browsing AUR packages.

\\{aurel-list-mode-map}"
  (make-local-variable 'aurel-list)
  (setq-local aurel-history-size aurel-list-history-size)
  (setq default-directory aurel-download-directory)
  (setq tabulated-list-format
        (apply #'vector
               (mapcar
                (lambda (col-spec)
                  (let ((name (car col-spec)))
                    (cons (or (cdr (assoc name aurel-list-column-name-alist))
                              (aurel-get-param-description name))
                          (cdr col-spec))))
                       aurel-list-column-format)))
  (setq tabulated-list-sort-key
        (list (aurel-get-param-description 'name)))
  (tabulated-list-init-header))

(defun aurel-list-show (list &optional buffer)
  "Display a LIST of packages in BUFFER.
LIST should have the form of `aurel-list'.
If BUFFER is nil, use (create if needed) buffer with the name
`aurel-list-buffer-name'."
  (let ((buf (get-buffer-create
              (or buffer aurel-list-buffer-name))))
    (with-current-buffer buf
      (aurel-list-show-1 list)
      (aurel-history-add (list 'aurel-list-show-1 list)))
    (pop-to-buffer-same-window buf)))

(defun aurel-list-show-1 (list)
  "Display a LIST of packages in current buffer.
LIST should have the form of `aurel-list'."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (aurel-list-mode)
  (setq aurel-list list)
  (setq tabulated-list-entries
        (aurel-list-get-entries list))
  (tabulated-list-print))

(defun aurel-list-get-entries (list)
  "Return list of values suitable for `tabulated-list-entries'.
Values are taken from LIST which should have the form of
`aurel-list'.
Use parameters from `aurel-list-column-format'."
  (mapcar
   (lambda (pkg)
     (let ((id   (car pkg))
           (info (cdr pkg)))
       (list id
             (apply #'vector
                    (mapcar
                     (lambda (col-spec)
                       (let* ((param (car col-spec))
                              (val (aurel-get-param-val param info)))
                         (aurel-get-string
                          val
                          ;; colorize outdated names
                          (and (eq param 'name)
                               (equal (aurel-get-param-val 'outdated info)
                                      aurel-outdated-string)
                               'aurel-info-outdated))))
                     aurel-list-column-format)))))
   list))

(defun aurel-list-get-package-info ()
  "Return package info for the current package."
  (let ((id (tabulated-list-get-id)))
    (if id
	(cdr (assoc id aurel-list))
      (user-error "No package here"))))

(defun aurel-list-describe-package (&optional arg)
  "Describe the current package.
With prefix (if ARG is non-nil), show results in a new info buffer."
  (interactive "P")
  (aurel-info-show (aurel-list-get-package-info)
                   (aurel-info-get-buffer-name arg)))

(defun aurel-list-download-package ()
  "Download current package.

With prefix, prompt for a directory with `aurel-directory-prompt'
to save the package; without prefix, save to
`aurel-download-directory' without prompting.

Use `aurel-list-download-function'."
  (interactive)
  (or (derived-mode-p 'aurel-list-mode)
      (user-error "Current buffer is not in aurel-list-mode"))
  (let ((dir (if current-prefix-arg
                 (read-directory-name aurel-directory-prompt
                                      aurel-download-directory)
               aurel-download-directory)))
    (funcall aurel-list-download-function
             (aurel-get-param-val 'pkg-url (aurel-list-get-package-info))
             dir)))


;;; Package info

(defgroup aurel-info nil
  "Buffer with information about AUR package."
  :group 'aurel)

(defface aurel-info-id
  '((t))
  "Face used for ID of a package."
  :group 'aurel-info)

(defface aurel-info-name
  '((t :inherit font-lock-keyword-face))
  "Face used for a name of a package."
  :group 'aurel-info)

(defface aurel-info-maintainer
  '((t :inherit button))
  "Face used for a maintainer of a package."
  :group 'aurel-info)

(defface aurel-info-url
  '((t :inherit button))
  "Face used for URLs."
  :group 'aurel-info)

(defface aurel-info-version
  '((t :inherit font-lock-builtin-face))
  "Face used for a version of a package."
  :group 'aurel-info)

(defface aurel-info-category
  '((t :inherit font-lock-comment-face))
  "Face used for a category of a package."
  :group 'aurel-info)

(defface aurel-info-description
  '((t))
  "Face used for a description of a package."
  :group 'aurel-info)

(defface aurel-info-license
  '((t))
  "Face used for a license of a package."
  :group 'aurel-info)

(defface aurel-info-votes
  '((t :weight bold))
  "Face used for a number of votes of a package."
  :group 'aurel-info)

(defface aurel-info-outdated
  '((t :inherit font-lock-warning-face))
  "Face used if a package is out of date."
  :group 'aurel-info)

(defface aurel-info-not-outdated
  '((t))
  "Face used if a package is not out of date."
  :group 'aurel-info)

(defface aurel-info-date
  '((t :inherit font-lock-constant-face))
  "Face used for dates."
  :group 'aurel-info)

(defface aurel-info-size
  '((t :inherit font-lock-variable-name-face))
  "Face used for size of installed package."
  :group 'aurel-info)

(defcustom aurel-info-buffer-name "*AUR Package Info*"
  "Default name of the buffer with information about an AUR package."
  :type 'string
  :group 'aurel-info)

(defcustom aurel-info-format "%-16s: "
  "String used to format a description of each package parameter.
It should be a '%s'-sequence.  After inserting a description
formatted with this string, a value of the paramter is inserted."
  :type 'string
  :group 'aurel-info)

(defcustom aurel-info-fill-column 60
  "Column used for filling (word wrapping) a description of a package.
This value does not include the length of a description of the
parameter, it is added to it; see `aurel-info-format'."
  :type 'integer
  :group 'aurel-info)

(defcustom aurel-info-download-function 'aurel-download-unpack-dired
  "Function used for downloading AUR package from package info buffer.
It should accept 2 arguments: URL of a downloading file and a
destination directory."
  :type 'function
  :group 'aurel-info)

(defcustom aurel-info-history-size 100
  "Maximum number of items saved in history of package info buffer.
If 0, the history is disabled."
  :type 'integer
  :group 'aurel-info)

(defcustom aurel-info-installed-package-string
  "\n\nThe package is installed:\n\n"
  "String inserted in info buffer if a package is installed.
It is inserted after printing info from AUR and before info from pacman."
  :type 'string
  :group 'aurel-info)

(defvar aurel-info-insert-params-alist
  '((id                . aurel-info-id)
    (name              . aurel-info-name)
    (maintainer        . aurel-info-insert-maintainer)
    (version           . aurel-info-version)
    (installed-version . aurel-info-version)
    (category          . aurel-info-category)
    (license           . aurel-info-license)
    (votes             . aurel-info-votes)
    (first-date        . aurel-info-date)
    (last-date         . aurel-info-date)
    (install-date      . aurel-info-date)
    (build-date        . aurel-info-date)
    (description       . aurel-info-insert-description)
    (outdated          . aurel-info-insert-outdated)
    (pkg-url           . aurel-info-insert-url)
    (home-url          . aurel-info-insert-url)
    (aur-url           . aurel-info-insert-url)
    (installed-size    . aurel-info-size))
  "Alist for inserting parameters into info buffer.
Car of each assoc is a symbol from `aurel-param-description-alist'.
Cdr is a symbol for inserting a value of a parameter.  If the
symbol is a face name, use it for the value; if it is a function,
it is called with the value of the parameter.")

(defvar aurel-info-parameters
  '(id name version maintainer description home-url aur-url
    license category votes outdated first-date last-date)
  "List of parameters displayed in package info buffer.
Each parameter should be a symbol from `aurel-param-description-alist'.
The order of displayed parameters is the same as in this list.
If nil, display all parameters with no particular order.")

(defvar aurel-info-installed-parameters
  '(installed-version architecture installed-size provides depends
    required optional-for conflicts replaces packager
    build-date install-date)
  "List of parameters of an installed package displayed in info buffer.
Each parameter should be a symbol from `aurel-param-description-alist'.
The order of displayed parameters is the same as in this list.
If nil, display all parameters with no particular order.")

(defvar aurel-info nil
  "Alist with package info.

Car of each assoc is a symbol from `aurel-param-description-alist'.
Cdr - is a value (number or string) of that parameter.")

(defvar aurel-info-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "q" 'quit-window)
    (define-key map "d" 'aurel-info-download-package)
    (define-key map "\t" 'forward-button)
    (define-key map [backtab] 'backward-button)
    (define-key map "l" 'aurel-history-back)
    (define-key map "r" 'aurel-history-forward)
    map)
  "Keymap for `aurel-info-mode'.")

(defun aurel-info-get-buffer-name (&optional unique)
  "Return a name of an info buffer.
If UNIQUE is non-nil, make the name unique."
  (if unique
      (generate-new-buffer aurel-info-buffer-name)
    aurel-info-buffer-name))

(define-derived-mode aurel-info-mode nil "AURel-info"
  "Major mode for displaying information about an AUR package.

\\{aurel-info-mode-map}"
  (make-local-variable 'aurel-info)
  (setq-local aurel-history-size aurel-info-history-size)
  (setq buffer-read-only t)
  (setq default-directory aurel-download-directory))

(defun aurel-info-show (info &optional buffer)
  "Display package information INFO in BUFFER.
INFO should have the form of `aurel-info'.
If BUFFER is nil, use (create if needed) buffer with the name
`aurel-info-buffer-name'."
  (let ((buf (get-buffer-create
              (or buffer aurel-info-buffer-name))))
    (with-current-buffer buf
      (aurel-info-show-1 info)
      (aurel-history-add (list 'aurel-info-show-1 info)))
    (pop-to-buffer-same-window buf)))

(defun aurel-info-show-1 (info)
  "Display package information INFO in current buffer.
INFO should have the form of `aurel-info'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (apply 'aurel-info-print
           info aurel-info-parameters)
    (when (aurel-get-param-val 'installed-name info)
      (insert aurel-info-installed-package-string)
      (apply 'aurel-info-print
             info aurel-info-installed-parameters)))
  (goto-char (point-min))
  (aurel-info-mode)
  (setq aurel-info info))

(defun aurel-info-print (info &rest params)
  "Insert (pretty print) package INFO into current buffer.
Each element from PARAMS is a parameter to insert (symbol from
`aurel-param-description-alist'."
  (mapc (lambda (param)
          (aurel-info-print-param
           param (aurel-get-param-val param info)))
        params))

(defun aurel-info-print-param (param val)
  "Insert description and value VAL of a parameter PARAM at point.
PARAM is a symbol from `aurel-param-description-alist'.
Use `aurel-info-format' to format descriptions of parameters."
  (let ((desc (aurel-get-param-description param))
        (insert-val (cdr (assoc param
                                aurel-info-insert-params-alist))))
    (insert (format aurel-info-format desc))
    (if (functionp insert-val)
        (funcall insert-val val)
      (insert (aurel-get-string val
                                (and (facep insert-val) insert-val))))
    (insert "\n")))

(defun aurel-info-insert-maintainer (name)
  "Make button from maintainer NAME and insert it at point."
  (if (string= name aurel-empty-string)
      (insert name)
    (insert-button
     name
     'face 'aurel-info-maintainer
     'action (lambda (btn)
               (aurel-maintainer-search (button-label btn)
                                        current-prefix-arg))
     'follow-link t
     'help-echo "mouse-2, RET: Find the packages by this maintainer")))

(defun aurel-info-insert-url (url)
  "Make button from URL and insert it at point."
  (insert-button
   url
   'face 'aurel-info-url
   'action (lambda (btn) (browse-url (button-label btn)))
   'follow-link t
   'help-echo "mouse-2, RET: Browse URL"))

(defun aurel-info-insert-outdated (val)
  "Insert string VAL at point.
If VAL is \"yes\", use `aurel-info-outdated' face.
If VAL is \"no\", use `aurel-info-not-outdated' face."
  (let ((face (if (string= "yes" (downcase val))
                  'aurel-info-outdated
                'aurel-info-not-outdated)))
    (insert (propertize val 'face face))))

(defun aurel-info-get-filled-string (str col)
  "Return string by filling a string STR.
COL controls the width for filling."
  (with-temp-buffer
    (insert str)
    (let ((fill-column col)) (fill-region (point-min) (point-max)))
    (buffer-string)))

(defun aurel-info-insert-description (str)
  "Format and insert string STR at point.
Use `aurel-info-fill-column'."
  (let ((parts (split-string (aurel-info-get-filled-string
                              str aurel-info-fill-column)
                             "\n")))
    (insert (propertize (car parts) 'face 'aurel-info-description))
    (dolist (part (cdr parts))
      (insert "\n"
              (format aurel-info-format "")
              (propertize part 'face 'aurel-info-description)))))

(defun aurel-info-download-package ()
  "Download current package.

With prefix, prompt for a directory with `aurel-directory-prompt'
to save the package; without prefix, save to
`aurel-download-directory' without prompting.

Use `aurel-info-download-function'."
  (interactive)
  (or (derived-mode-p 'aurel-info-mode)
      (user-error "Current buffer is not in aurel-info-mode"))
  (let ((dir (if current-prefix-arg
                 (read-directory-name aurel-directory-prompt
                                      aurel-download-directory)
               aurel-download-directory)))
    (funcall aurel-info-download-function
             (aurel-get-param-val 'pkg-url aurel-info)
             dir)))

(provide 'aurel)

;;; aurel.el ends here
