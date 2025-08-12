# This script sends an iMessage to a specified recipient.
# It is designed to be called from a command-line script like 'osascript'.
#
# Arguments:
#   argv[1]: The message text to send (e.g., "ALERT: Motion detected!")
#   argv[2]: The recipient's phone number or Apple ID (e.g., "+15551234567")

on run argv
    # Check if the correct number of arguments were provided.
    if count of argv is not 2 then
        log "Error: This script requires exactly two arguments: message and recipient."
        return
    end if

    set alertMessage to item 1 of argv
    set recipientAddress to item 2 of argv

    try
        tell application "Messages"
            # Get the iMessage service to ensure we are sending an iMessage.
            set iMessageService to 1st service whose service type = iMessage
            # Get the target buddy (contact).
            set targetBuddy to buddy recipientAddress of iMessageService
            # Send the message.
            send alertMessage to targetBuddy
        end tell
    on error errMsg
        log "AppleScript Error: " & errMsg
    end try
end run
