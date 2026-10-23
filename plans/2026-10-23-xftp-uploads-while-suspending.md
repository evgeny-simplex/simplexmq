# XFTP uploads while the agent is suspending

On iOS, a file sent shortly before the app left the foreground was delivered only after the app was opened again: once the agent began to suspend, the next chunk was not started, and the result of the chunk in flight was recorded only in foreground.
While the agent is suspending, it continues the uploads that it started in foreground. Their files are counted by a new operation, `AOSndFiles`, with its own count and set, in a stage between `AORcvNetwork` and `AOMsgDelivery`; the next stage is entered after the chat deletes these files; at the suspend timeout, the stage of `AOSndNetwork` is entered if the agent is still suspending.

Chat side: https://github.com/evgeny-simplex/simplex-chat/pull/5

## Decisions

- Stages of `suspendAgent` with a timeout above 0:

  | Order | Operation | Count | At count 0 |
  |---|---|---|---|
  | 1 | `AORcvNetwork` | received transmission batches in processing by the subscriber | `AOSndFiles` suspended |
  | 2 | `AOSndFiles` | counted files | `AOMsgDelivery` suspended |
  | 3 | `AOMsgDelivery` | submitted messages not yet taken by delivery workers | `AOSndNetwork` suspended |
  | 4 | `AOSndNetwork` | delivery workers and async command workers processing work | `AODatabase` suspended |
  | 5 | `AODatabase` | database transactions | `SUSPENDED` sent; agent state `ASSuspended` |

  - The actions of "At count 0" are taken only while the agent state is `ASSuspending`.
  - `AONtfNetwork` is suspended at the start; no stage is delayed by its count.
  - After the timeout, if the agent is still suspending, stage 4 is entered whatever stage is in progress, and stage 5 is entered by the same rule.
- Counted files, the set `sndFilesInProgress`:
  - inserted: files started by `xftpStartSendFile'` while the agent state is `ASForeground`;
  - removed:
    - files deleted by `deleteSndFilesInternal`, after its database work, also after an exception;
    - files expired by TTL cleanup, before their prefix path and row are deleted.
- `deleteSndFilesInternal` is run by `xftpDeleteSndFileInternal`, which is called by the chat after `SFDONE` and `SFERR`.
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

  - At a closed gate, the send prepare and upload workers wait until the agent state is `ASForeground`.
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
  - `AgentClient` (:379-380), fields created in `newAgentClient` (:554-555):
    - `sndFilesOp :: TVar AgentOpState`;
    - `sndFilesInProgress :: TVar (Set SndFileId)`.
  - `AgentOperation`: `AOSndFiles` (:480).
  - `sndFilesOp` added to:
    - `agentOpSel` (:487);
    - `agentOperations` (:493).
  - `endAgentOperation` (:2370-2384): at the end of `AORcvNetwork`, `AOSndFiles` is suspended; at the end of `AOSndFiles`, `suspendMsgDelivery` is called.
  - `suspendMsgDelivery` (:2386-2389): `AOMsgDelivery` is suspended; `suspendSendingAndDatabase` is called when its count is 0.
  - new:
    - `addSndFileInProgress` (:2421-2424);
    - `removeSndFileInProgress` (:2426-2429);
    - `waitWhileSndFilesSuspended` (:2463-2473), the gate.
- `src/Simplex/Messaging/Agent.hs`:
  - `suspendAgent` (:3446-3448): `AORcvNetwork`, `AOSndFiles`, then `suspendMsgDelivery`.
  - `deleteSndFilesExpired` (:3547), local to `cleanupManager`: `removeSndFileInProgress`.
- `src/Simplex/FileTransfer/Agent.hs`:
  - `xftpStartSendFile'` (:406): `addSndFileInProgress` when `ASForeground`.
  - `assertSndFilesActive` in place of `assertAgentForeground`:
    - `runXFTPSndPrepareWorker` (:423, :486, :506);
    - `runXFTPSndWorker` (:527, :548, :559).
  - `uploadFileChunk` (:561): `waitWhileSndFilesSuspended` in place of `waitUntilForeground`.
  - `deleteSndFilesInternal` (:662): `removeSndFileInProgress` in `E.finally`.
  - `assertSndFilesActive` (:748-751): `throwWhenInactive`, then the gate.

## Tests

`tests/XFTPAgent.hs`, "agent XFTP API":
- "should complete sending file while agent is suspending" (:618):
  - suspend timeout 60 s;
  - all `SFPROG` within 30 s, then `SFDONE`;
  - events absent for 300 ms;
  - after `xftpDeleteSndFileInternal`, `SUSPENDED` within 5 s.
- "should suspend on timeout when file is not sent" (:633):
  - XFTP server down, suspend timeout 0.5 s: `SUSPENDED`;
  - server started: events absent for 1 s;
  - after `foregroundAgent`, `SFDONE`.
- "should not wait for file started while agent is suspending" (:649):
  - file 1 started, suspend timeout 60 s, file 2 started;
  - `SFDONE` of file 1 within 30 s;
  - after `xftpDeleteSndFileInternal` of file 1, `SUSPENDED` within 5 s; events of file 2 before it are skipped.
- "should continue sending file when another file is deleted twice while agent is suspending" (:663):
  - file 1 of 128 KB and file 2 of 17 MB started, suspend timeout 60 s;
  - `xftpDeleteSndFileInternal` of file 1, twice;
  - `SFDONE` of file 2 within 30 s; `SUSPENDED` before it: test failure;
  - after `xftpDeleteSndFileInternal` of file 2, `SUSPENDED` within 5 s.

`tests/AgentTests/FunctionalAPITests.hs`, "Suspending agent":
- "should send messages queued after file is sent before agent is suspended" (:3137):
  - b starts a file, suspend timeout 60 s;
  - once `sndFilesOp` is suspended, the `opSuspended` flags of `rcvNetworkOp`, `sndFilesOp`, `msgDeliveryOp`: `[True, True, False]`;
  - after `SFDONE`, `sendMessage` and `xftpDeleteSndFileInternal`: `[True, True, True]`;
  - `SENT`, then `SUSPENDED` within 5 s;
  - a receives the message.

## Open questions

1. Remove counted files whose uploads ended or stopped and that this agent has not deleted? While such files stay counted, the agent waits for the suspend timeout at each later suspension. Cases:
   - in the shared database:
     - the upload of the file is completed by the share extension;
     - the file is deleted by the share extension or the NSE;
     - the file is marked deleted by the share extension or the NSE; `deleteSndFilesDeleted` in this process then deletes such rows without `removeSndFileInProgress`;
   - the chat's subscriber is cancelled by `stopChatController` (simplex-chat `src/Simplex/Chat/Library/Commands.hs:371`, run by `APIStopChat`) during `SFDONE` handling, before the deletion of the agent file;
   - the upload worker is stopped by `stopChatController` after the last chunk is recorded as uploaded (`src/Simplex/FileTransfer/Agent.hs:564`) and before `SFDONE` is queued (:577): the row is left with status `SFSUploading` without pending replicas, or with status `SFSComplete`; neither worker selects it, and `SFDONE` is never queued;
   - the agent fails to load a work item: the file is marked `failed = 1` without `SFERR`.

   Recommended:
   - at the start of `suspendAgent` with a timeout above 0, while `AODatabase` is not suspended, files whose rows are absent or flagged `deleted = 1` or `failed = 1` are removed, with one query; the flag is checked and the database operation is begun in one STM transaction;
   - files with complete or error rows are kept in the set by that query;
   - in `closeAgentClient`, every counted file is removed by `removeSndFileInProgress`.
