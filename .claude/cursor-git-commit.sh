if [ -z "$1" ]; then
    echo "Usage: gitai-project <project name>"
    return 1
fi
osascript <<EOF
tell application "System Events"
    tell process "Cursor"
        set targetWindow to missing value
        repeat with w in windows
            if name of w contains "$1" then
                set targetWindow to w
                exit repeat
            end if
        end repeat
        
        if targetWindow is not missing value then
            perform action "AXRaise" of targetWindow
            delay 0.2
            keystroke "g" using {command down, control down}
        else
            error "Window not found containing '$1'"
        end if
    end tell
end tell

tell application "Cursor" to activate
EOF