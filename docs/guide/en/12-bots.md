# DS Bot

DS Bot is a plugin on the host. Each Bot has its own role, chat and memory. On a host that supports DS Bot, open it below the filters in the conversation drawer. The entry stays visible when you change the filter or workspace. You can also open it from All features or tap [Open](dshgo://open/ds-bot). The page shows the host name at the top, followed by group chats and then Bots.

## Mobile support

**DS Bot isn't on mobile yet** means this host's DS Bot has no usable mobile interface. Tap **Open in DSH Web** to use it there for now. After the plugin is updated and restarted on the host, tap **Retry** to check again. This message doesn't mean your Bots or group chats have been deleted.

If DS Bot isn't detected, the page offers installation or a command to run on the computer. If the host already exposes DS Bot over DSH Remote, connect and open DS Bot from **All features**. On request-only hosts, the app checks for updates to Bots and group chats periodically. If the host does not expose DS Bot, connect through SSH or use DSH Web on the computer.

## Organizing group chats and Bots

On hosts that support saved layouts, tap Edit organization in the Bot section of the DS Bot page. Press and hold the drag handle next to a group chat or Bot to reorder it. Use the ⋮ menu to move a Bot to another folder. The Bot section pins Main Bots at the top and keeps other Bots in folders that start collapsed. Tap a folder name to expand it. After you save, compatible DSH Go clients connected to the same host load the shared layout.

When the host has the standalone DSH Go Layout plugin, it stores folders and ordering. If you previously used the DS Bot layout extension, tap Copy DS Bot layout on the DS Bot page. Wait for the app to confirm the copy before returning to the official DS Bot package.

## Group goals

Open a group chat, open its details from the top bar, then tap Group goal. Choose Set a goal, enter the outcome you want, and tap Send goal request. The group admin Bot will discuss the objective and acceptance criteria with you in the chat. After the goal starts, use the same page to review progress and pause, resume, or stop it as its status allows.

## Sending photos

In a Bot or group chat, tap ＋ next to the message box to choose photos or take a picture. Preview or remove the selected images, then send them with or without a caption. The host must support DS Bot image messages. Tap an image thumbnail in the chat history to open it. The host applies the chat's file access permissions when it serves workspace images in Bot replies.

## Using skills

In a direct chat with a Bot that uses the native host engine, open the skills list next to the message box. Choose a skill available in the current chat. The app adds `/skill-name` to the draft. Add your request and send it to use the skill.

## Working directory

Open a Bot or group chat, open its details from the top bar, then tap **Working directory**. You are choosing a directory on the connected host; a remote host's directories aren't on your phone.

1. Check **Current directory** and choose from the directories supplied by the host.
2. Tap **Save**, check the directory shown in “Use this working directory?”, then tap **Save** again.

For a Bot, choose **Team workspace** to restore the default. For a group chat, choose **Each Bot’s own directory** to let members use their individual working directories.

If the connection or folder has changed, close the sheet and open it again. If the host refuses a directory, it may be gone, inaccessible or protected; choose another or retry.

## Duplicate a Bot

In the Bot's details, tap **Duplicate Bot**, read the explanation and confirm. The new Bot keeps its job, instructions and model settings, starts with a fresh chat and personal memory, and gets its name from the host. When a model is available, it opens with a greeting.

After copying, the app normally opens the new Bot. If it says the copy will appear in the list shortly, return to the DS Bot list to check; you don't need to duplicate it again. If disconnected, on a different host or in read-only mode, restore the connection and reopen the details before trying.
