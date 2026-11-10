- Review Comments
- Adjust code in some places to look more like before
- Sync Branches appropiately
- Regression on hard delete vs trashing:  
The trash=False parameter on dired_delete is currently a no-op — nothing in the method branches on it.
Also, Sublime does only delete to trash, so maybe just remove that hotkey?
Or reimplement the actual behaviour lost in
"57459c3 Simplify "dired_delete" command by deferring to Sublime Text"

- Merge with dired?  
About Issues for possibly merging with https://github.com/kublaios/dired

- Delete cannot remove a junction or symlinked directory: shutil.rmtree raises 'Cannot call rmtree on a symbolic link' (uncaught) #5  
should be fixed with FileBrowser, it uses sublimes deletion commands which afaik handle all these correcty (not tested)

- Move onto an existing name raises an uncaught shutil.Error: nothing is moved, no message, no refresh #6  
works with FileBrowser, it uses sublimes deletion commands which (on windows) will open the os "Replace or Skip Files?" Dialog (tested)

