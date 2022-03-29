((nim-mode . ((nim-compile-default-command . ("r" "-r" "--gc:arc" "--threads:on" "--deepcopy:on" "--verbosity:0" "--hint[Processing]:off" "--excessiveStackTrace:on"))
              (lsp-nim-nimsuggest-mapping . [(:projectFile "src/nim/translate.nim" :fileRegex ".*\.nim$")])
              ))
 (nil . ((lsp-restart 'always))))
