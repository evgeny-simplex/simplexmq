# XFTP uploads while the agent is suspending

On iOS, a file sent just before the app leaves the foreground was delivered only after the app was opened again: the agent stopped XFTP uploads at the next chunk once suspension began.
Uploads started in foreground continue while the agent is suspending; suspension waits for them in a new stage, until the chat deletes their files or the suspend timeout.

Chat side: https://github.com/evgeny-simplex/simplex-chat/pull/5

## Decisions

- Stages of `suspendAgent` with a timeout above 0:

  | Order | Operation | Count |
  |---|---|---|
  | 1 | `AORcvNetwork` | received transmissions in processing |
  | 2 | `AOSndFiles` | counted files |
  | 3 | `AOMsgDelivery` | submitted messages not yet taken by delivery workers |
  | 4 | `AOSndNetwork` | delivery workers processing a message |
  | 5 | `AODatabase` | database transactions |

  - A stage is entered when the count of the previous stage is 0.
  - `SUSPENDED` is sent when the count of `AODatabase` is 0.
  - After the timeout, `AOSndNetwork` and `AODatabase` are suspended.
- Counted files:
  - added: files started by `xftpStartSendFile'` while the agent state is `ASForeground`;
  - removed: files deleted by `deleteSndFilesInternal`, after its database work, also on exception; the chat calls it after `SFDONE` and `SFERR`;
  - removed: files expired by TTL cleanup, before its database work;
  - a file adds 1 to the count when it enters the set and subtracts 1 when it leaves it.
- Uncounted files:
  - files resumed at worker start;
  - files started while suspending or suspended.
- Gate of the send prepare and upload workers:

  | Agent state | Counted files | `AOSndNetwork` suspended | Gate |
  |---|---|---|---|
  | `ASForeground` | any | any | open |
  | `ASSuspending` | above 0 | no | open |
  | `ASSuspending` | 0 | any | closed |
  | `ASSuspending` | any | yes | closed |
  | `ASSuspended` | any | any | closed |

  - Work at a closed gate waits until foreground.
  - While the gate is open, uncounted files are uploaded too.
- Receive and delete workers: unchanged.
- `foregroundAgent`: suspended flags cleared; counted files kept.

```
xftpStartSendFile' f           ASForeground -> add f
deleteSndFilesInternal fs      rows deleted or marked deleted; finally: remove each f
deleteSndFilesExpired f        remove f; prefix path and row deleted
add f                          f not in set -> insert f; count + 1
remove f                       f in set -> delete f; endAgentOperation AOSndFiles
```

## Mechanics

- `src/Simplex/Messaging/Agent/Client.hs`:
  - `AgentClient`: `sndFilesOp :: TVar AgentOpState`, `sndFilesInProgress :: TVar (Set SndFileId)` (:379-380), created in `newAgentClient` (:554-555).
  - `AgentOperation`: `AOSndFiles` (:480).
  - `agentOpSel` (:487), `agentOperations` (:493): `sndFilesOp`.
  - `endAgentOperation` (:2370-2384): `AORcvNetwork` suspends `AOSndFiles`; `AOSndFiles` calls `suspendMsgDelivery`.
  - `suspendMsgDelivery` (:2386-2389): suspends `AOMsgDelivery`, then `suspendSendingAndDatabase`.
  - `addSndFileInProgress` (:2421-2424), `removeSndFileInProgress` (:2426-2429).
  - `waitWhileSndFilesSuspended` (:2463-2473): the gate.
- `src/Simplex/Messaging/Agent.hs`:
  - `suspendAgent` (:3446-3448): `AORcvNetwork`, `AOSndFiles`, then `suspendMsgDelivery`.
  - `cleanupManager`, `deleteSndFilesExpired` (:3547): `removeSndFileInProgress`.
- `src/Simplex/FileTransfer/Agent.hs`:
  - `xftpStartSendFile'` (:406): `addSndFileInProgress` when `ASForeground`.
  - `runXFTPSndPrepareWorker` (:423, :486, :506) and `runXFTPSndWorker` (:527, :548, :559): `assertSndFilesActive` in place of `assertAgentForeground`.
  - `uploadFileChunk` (:561): `waitWhileSndFilesSuspended` in place of `waitUntilForeground`.
  - `deleteSndFilesInternal` (:662): `removeSndFileInProgress` in `E.finally`.
  - `assertSndFilesActive` (:748-751): `throwWhenInactive`, then the gate.

## Tests

`tests/XFTPAgent.hs`, "agent XFTP API":
- "should complete sending file while agent is suspending" (:618):
  - suspend timeout 60 s;
  - all `SFPROG` within 30 s, then `SFDONE`;
  - `SUSPENDED` absent for 300 ms;
  - after the delete, `SUSPENDED` within 5 s.
- "should suspend on timeout when file is not sent" (:633):
  - XFTP server down, suspend timeout 0.5 s: `SUSPENDED`;
  - server started: snd events absent for 1 s;
  - after `foregroundAgent`, `SFDONE`.
- "should not wait for file started while agent is suspending" (:649):
  - file 1 started, suspend timeout 60 s, file 2 started;
  - `SFDONE` of file 1 within 30 s;
  - after the delete of file 1, `SUSPENDED` within 5 s; events of file 2 accepted.
- "should continue sending file when another file is deleted twice while agent is suspending" (:663):
  - file 1 of 128 KB and file 2 of 17 MB started, suspend timeout 60 s;
  - file 1 deleted twice;
  - `SFDONE` of file 2 within 30 s; an earlier `SUSPENDED` fails the test;
  - after the delete of file 2, `SUSPENDED` within 5 s.

`tests/AgentTests/FunctionalAPITests.hs`, "Suspending agent":
- "should send messages queued after file is sent before agent is suspended" (:3137):
  - b starts a file, suspend timeout 60 s;
  - once `sndFilesOp` is suspended, the `opSuspended` flags of `rcvNetworkOp`, `sndFilesOp`, `msgDeliveryOp`: `[True, True, False]`;
  - after `SFDONE`, `sendMessage` and the delete: `[True, True, True]`;
  - `SENT`, then `SUSPENDED` within 5 s;
  - a receives the message.

## Open questions

1. Files stay counted after their uploads end or stop, and each later suspension then waits for its timeout:
   - the share extension or the NSE completes, deletes or marks deleted the file in the shared database;
   - `deleteSndFilesDeleted` deletes rows without `removeSndFileInProgress`;
   - stopChat cancels the chat's subscriber during `SFDONE` handling, before the delete;
   - stopChat stops the upload worker between the last chunk and `updateSndFileComplete`;
   - a work item fails to load: the file is marked `failed = 1` without `SFERR`.

   Recommended:
   - at the start of `suspendAgent` with a timeout above 0, files whose rows are absent or flagged `deleted = 1` or `failed = 1` are removed, with one query;
   - files with complete or error rows stay counted: the chat deletes them after `SFDONE` or `SFERR`;
   - in `closeAgentClient`, every counted file is removed by `removeSndFileInProgress`.
