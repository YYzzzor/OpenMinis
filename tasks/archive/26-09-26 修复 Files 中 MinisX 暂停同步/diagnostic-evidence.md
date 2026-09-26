# 本轮精选原始诊断证据
来源为独立设备限定采样；无用户文件正文、认证凭据或聊天内容。

## iOS27原始系统dump
```text
Date/Time:         2026-09-26 03:10:38 +0000, (812085038.540863)
OS Version:        26A428
FP Version:        4838.0.125
uid:               501


3 providers, filtered by 'com.openminis.app.FileProvider/N{35}r'
Import Cookie: 未能完成该操作。未定义的错误：0
=====================================================
com.openminis.app.FileProvider
=====================================================
  + version: none
  + available system wide: 1
  + supports enumeration: 1
  + supports FPFS: 1
  + read-only: 0
  + extension storage URLs: (1)
    - <GroupContainers>/04121016-BD5B-4120-8599-C51AF231311B/F{19}e
  + file coordination purpose ID: com.openminis.app.FileProvider
  + display name: MinisX
  + bundle URL: ~/C{8}s/B{4}e/A{9}n/C{34}F/M{3}s.app/P{5}s/M{15}r.appex
  + containing bundle identifier: com.openminis.app
  + persona: none
  + document group name: group.com.openminis.app
  + supported file types: none
  + uses unique item identifiers across devices: 0
  + applies changes atomically: 0
  + supports failing upload on conflict: 0
  + push topics (development, opportunistic): (0)
  + push topics (production): (0)
  + push topics (production, opportunistic): (0)
  + push topics (development): (0)

-----------------------------------------------------
domain: (default) (hidden)
-----------------------------------------------------
 no process observed; grace period timer not running
  + features: 
  + root: <GroupContainers>/04121016-BD5B-4120-8599-C51AF231311B/F{19}e
  + FPDDomain instance: <FPDDomain:0x104520f00>
      - default backend: <FPDDomainExtensionBackend:0x10444c780>
      - extension backend: <FPDDomainExtensionBackend:0x10444c780>
      - deactivated backend: <(null):0x0>
      - volume: <FPDVolume:0x104447660 role:home dev:16777229 uuid:BF...4A '/S{4}m/V{5}s/D{2}a'>
  + persona: none
  + userInfo: 0 keys
  + indexer:

-----------------------------------------------------
domain: c{15}p.files (M{4}X)
-----------------------------------------------------
[32mforeground[39m foreground:{com.apple.DocumentsApp}; grace period timer not running
[33m alive (58958) via ExtensionKit[39m for:
     enumerator of s:com.openminis.app.FileProvider/c{15}p.files/root, al:n for pid=65225 name=Files path=/private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS.SimulatorRuntime-v24.1.434.0.3IRr0j/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/Applications/Files.app/Files isPOSIX=0
  + features: repl,syncTrash,
  + root: <FPFS>/FE145987-EB1F-43AB-8A94-0440CDF773FF
  + FPDDomain instance: <FPDDomain:0x104521040>
      - default backend: <FileProviderDaemon.FPDDomainFPFSBackend:0x104550400>
      - extension backend: <FPDDomainExtensionBackend:0x10444dc50>
      - deactivated backend: <(null):0x0>
      - volume: <FPDVolume:0x104447660 role:home dev:16777229 uuid:BF...4A '/S{4}m/V{5}s/D{2}a'>
  + persona: none
  + userInfo: 0 keys
  + indexer:
domain: com.openminis.app.FileProvider/c{15}p.files
      spDomainID:     0ECBA99E-4026-4CDF-BBFF-C4A1B2ECCC53
      scheduler:      <l:com.apple.fileprovider.indexing 🌕 1 🛏  registration:<from:2026-09-26 03:09:30 +0000 count:0>>
      enabled:        yes
      indexing:       no
      needs-auth:     no
      needs-indexing: no
      + telemetry info:
         count of files requested for redonation in the last day: 0
      errors:         0
      batch-indexed (since last startup): 0
      spotlightIndexer:
      eligibleForEmbeddings: true
      anchor: <A6056822-6F35-4E64-986D-A36F16164E8F update:1790388502477725952 deletions:0>
      pending-indexable-count: 0 (updates: 0, undownloaded: 0, overlap: 0, deletions: 0)
      total-indexable-count: 8 (items: 8, deletions: 0)
  + active enumerators:
    <fpfs:root requestedBy:65225 hasPresenter:no>
sync engine state:
    + upload progress: <gprogress:NSProgressFileOperationKindUploading url:<FPFS>/FE145987-EB1F-43AB-8A94-0440CDF773FF>
    + download progress: <gprogress:NSProgressFileOperationKindDownloading url:<FPFS>/FE145987-EB1F-43AB-8A94-0440CDF773FF>
    + database: version=v13.4.r202507081658 UUID=A6056822-6F35-4E64-986D-A36F16164E8F
    + FSEvent: UUID=44B13C29-6AFE-48BB-91B9-5164E19FBB1B StreamID=649732841
    + FP anchor: <page:<nil> anchor:Fq7UHjUbfOs=>
    + domain version: 0
    + features: evict_packages|mark_directories_as_locked
    + scheduling state: running
    + error generation: 25
    + disk import: no
    + stream reset: no
    + refresh speculative policy: no
    + directory manifest: not-loaded
    + database history:
      [2026-09-26 00:34:17.131+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (7568FF36-CA69-45D4-B314-BA98AA66C260)
      [2026-09-26 00:15:38.770+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (173746FB-19F2-4177-90E2-C10062014989)
      [2026-09-26 00:12:48.082+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (85F0FE6A-F525-406D-8803-8AD8032B1BAA)
      [2026-09-25 23:39:43.167+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (4E707D7A-EC78-4546-9DF5-4F983BF54AEA)
      [2026-09-25 23:20:32.632+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (2A3454C3-76A3-49AC-9109-581A8996273C)
      [2026-09-25 23:20:29.153+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (4E707D7A-EC78-4546-9DF5-4F983BF54AEA)
      [2026-09-22 00:22:53.383+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (24410247-384F-4635-8020-7E2F33F7A22E)
      [2026-09-22 00:05:45.432+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (A8991CAB-C4D0-4E2A-8116-06AB6039F8DB)
      [2026-09-21 23:59:32.538+0800] OS:26A428 DB:v13.4.r202507081658 FS:4838.0.125 FP:1.13 (C0EEA9B1-4088-4B7C-9888-3B15757DD8B3)
      Creation reason: domainCreation
    + processing requests
    + reconciliation (8 entries):
     ⬇︎  <fs:✅  <unknown> materializingParent> <-> <fp:⏳  memory fields:all ⧗throttling> dir sched:utility#1790006372.6156569 rank:<s:1790388502395604224 c:0> <spec:isNotIndexable>⏳
     ⬇︎  <fs:✅  <unknown> materializingParent> <-> <fp:⏳  skills fields:all ⧗throttling> dir sched:utility#1790006372.6156569 rank:<s:1790388502477725952 c:0> <spec:isNotIndexable>⏳
    🔍  <fs:✅  <unknown>> <-> <fp:⏳  memory/SOUL.md fields:all ⧗parentCreation> doc sched:utility#1790006373.9336329 rank:<s:1790006373935472128 c:max> <spec:isNotIndexable>
    🔍  <fs:✅  <unknown>> <-> <fp:⏳  skills/skill-creator fields:all ⧗parentCreation> dir sched:utility#1790007786.045608 rank:<s:1790007787207426048 c:0>
    🔍  <fs:✅  <unknown>> <-> <fp:⏳  skills/skill-creator/SKILL.md fields:all ⧗parentCreation> doc sched:utility#1790007787.115201 rank:<s:1790007787570806016 c:max> <spec:isNotIndexable>
        <fs:✅  root content:watch sver:root/F{34}F cver:71920597> <-> <fp:✅  .root content:watch sver:1790006369.8804035 cver:1790006369.8804035> dir sched:utility#1790006374.310841 rank:<s:1790007787208045056 c:0>
        <fs:✅  trash content:watch sver:trash/.{4}h cver:71920632> <-> <fp:✅  .trash sver: cver:> dir sched:utility#1790006374.203868 rank:<s:1790006374204152064 c:0> <spec:isNotIndexable>
        <fs:✅  fileID(71920683) content:watch sver:root/s{4}d cver:71920683> <-> <fp:✅  shared sver:1790006369.8804011 cver:1790006369.8804011> dir sched:utility#1790006374.185542 rank:<s:1790006374201640960 c:0> <spec:isNotIndexable>
    
    + background
      cacheDelete enabled: true
      download scheduler: <l:com.apple.fileproviderd.background-download 🌕 1 🛏  registration:<from:2026-09-26 03:09:30 +0000 count:0> usage:2026-09-26 03:09:41 +0000>
      background downloader pacer: <dirty:false last:1790007788 lastDownloadsAllowedReset:1790006372 totalDownloadCount:0 lastIndexingBarrier: Optional(FileProviderDaemon.DatabaseIndexAnchor.anchor(1790388502477725952))>
      speculative disk management: <inGreedyState:true>
      upload scheduler: <l:com.apple.fileproviderd.background-upload-non-expensive 🌕 1 🛏  registration:<from:2026-09-26 03:09:30 +0000 count:0> usage:2026-09-26 03:09:30 +0000>
    + throttling: no expiration scheduled
    + propagation jobs
    + item jobs
    + snapshot fs (3 entries):
      <s:root p:root n:"F{34}F/" dir child:2 m:rwxS ct:1790006372.346226 mt:1790006372.346241 v:sver:root/F{34}F cver:71920597 rec:<dls:1 nev:0 ev:0 dlswc:0>>
       <s:fileID(71920683) p:root n:"s{4}d/" dir dls child:65533 m:rwxe ct:1790006369.8804011 mt:1790006369.8804011 v:sver:root/s{4}d cver:71920683 rec:<dls:1 nev:0 ev:0 dlswc:0>>
      <s:trash p:trash n:".{4}h/" dir dls child:65533 m:rwx ct:1790006372.688404 mt:1790006372.688404 v:sver:trash/.{4}h cver:71920632 rec:<dls:1 nev:0 ev:0 dlswc:0>>
      + counters: createCount=0 updateCount=0 deleteCount=0 resetDate=2026-09-26 03:09:29 +0000
    + FS roots
      <FPFS>/FE145987-EB1F-43AB-8A94-0440CDF773FF [ino:71920597]
    
    + throttling: next expiration in 1h3min
      i:memory create-item: 🛑 last:'1790388502 (-1h2min)' next:'1790396070 (1h3min)' count:15 error:'NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}' domain:none category:<nil> prio:utility
      i:skills create-item: 🛑 last:'1790388502 (-1h2min)' next:'1790396250 (1h6min)' count:15 error:'NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}' domain:none category:<nil> prio:utility
    + propagation jobs
    + item jobs
    + snapshot fp (8 entries):
      <s:.root p:.root n:"M{4}X/" dir child:65533 m:rwxel ct:1790006369.8801649 mt:1790006369.8804035 v:sver:1790006369.8804035 cver:1790006369.8804035 nsattr:<cap:r-------- ul:uploaded cp:system nsp:system> rec:<!del:7 !excl:7>>
       <s:shared p:.root n:"s{4}d/" dir child:65533 m:rwxe ct:1790006369.8804011 mt:1790006369.8804011 v:sver:1790006369.8804011 cver:1790006369.8804011 nsattr:<cap:rw------- ul:uploaded cp:system nsp:inherited(lazy)> rec:<!del:1 !excl:1>>
       <s:memory p:.root n:"m{4}y/" dir child:65533 m:rwxel ct:1790006369.8802583 mt:1790006369.880991 v:sver:1790006369.880991 cver:1790006369.880991 nsattr:<cap:r-------- ul:uploaded cp:system nsp:inherited(lazy)> rec:<!del:2 !excl:2>>
        <s:memory/SOUL.md p:memory n:"S{2}L.md" doc sz:45 m:r--el ct:1790006369.8806715 mt:1790006369.8807492 v:sver:1790006369.8807492 cver:1790006369.8807492 nsattr:<cap:r-------- ul:uploaded cp:system nsp:system>>
       <s:skills p:.root n:"s{4}s/" dir child:65533 m:rwxel ct:1790006369.8803205 mt:1790006369.8803205 v:sver:1790007781.7243834 cver:1790007781.7243834 nsattr:<cap:r-------- ul:uploaded cp:system nsp:inherited(lazy)> rec:<!del:3 !excl:3>>
        <s:skills/skill-creator p:skills n:"s{11}r/" dir child:65533 m:rwxel ct:1790007781.7243752 mt:1790007781.7249684 v:sver:1790007781.7249684 cver:1790007781.7249684 nsattr:<cap:r-------- ul:uploaded cp:system nsp:inherited(lazy)> rec:<!del:2 !excl:2>>
         <s:skills/skill-creator/SKILL.md p:skills/skill-creator n:"S{3}L.md" doc sz:3946 m:r--el ct:1790007781.7246342 mt:1790007781.7247381 v:sver:1790007781.7247381 cver:1790007781.7247381 nsattr:<cap:r-------- ul:uploaded cp:system nsp:system>>
      <s:.trash p:.trash n:".{4}h/" dir child:65533 m:rwxhe ct:0.0 mt:0.0 v:sver: cver: nsattr:<cap:rw------- cp:system nsp:system> rec:<!del:1 !excl:1>>
      + counters: createCount=0 updateCount=0 deleteCount=0 resetDate=2026-09-26 03:09:29 +0000
    
    + FP Jobs accounted in Global Progress:
      + Content counters : 0 items with size 0
      + Materialize counters : 0 items with size 0
      + Jobs counters : 0 items with size 0
    
    + FSCounters: lookupCount=6 scanCount=0 droppedEventCount=0 resetDate=2026-09-26 03:09:28 +0000
    + DBCounters: flushCount=7 resetDate=2026-09-26 03:09:29 +0000
    


== CloudStorage xattrs ==
=========================
FE145987-EB1F-43AB-8A94-0440CDF773FF
    com.apple.file-provider-domain-id: com.openminis.app.FileProvider/com.openminis.app.files

== FileProvider xattrs ==
=========================
FE145987-EB1F-43AB-8A94-0440CDF773FF
    com.apple.file-provider-domain-id: com.openminis.app.FileProvider/com.openminis.app.files

== action operation engine ==
=================
0 operations

apps monitor [0;1;30mnot-active[0m
-----------------------------------------------------
[0;1;37m0[0m apps monitored.

== Trial configuration ==
{
  "COREOS_FPFS_CONFIG" : {
    "rollout" : {

    },
    "experiment" : {

    }
  },
  "COREOS_FPFS_SPECULATIVE_DOWNLOADS" : {
    "rollout" : {

    },
    "experiment" : {

    }
  }
}

```

## fp-retry-stream.log
```text
1368: 2026-09-26 11:16:34.868 Df fileproviderd[58721:a15012] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳8a6 ✅  done executing <J1 ⏳  create-item(propagated:<memory dbver:1 domver:<nil>> requested:<p:root n:"m{4}y" dir dls child:65533 m:rwxl ct:1790006369.8802583 mt:1790006369.880991>) why:itemChangedRemotely sched:utility#1790006372.6156569 from:<dir-ino(73433014)> ⧗persisted> [duration 38ms959µs]
1405: 2026-09-26 11:16:34.878 Df fileproviderd[58721:a15012] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳8a9 ✅  done executing <J2 ⏳  create-item(propagated:<skills dbver:2 domver:<nil>> requested:<p:root n:"s{4}s" dir dls child:65533 m:rwxl ct:1790006369.8803205 mt:1790006369.8803205>) why:itemChangedRemotely sched:utility#1790006372.6156569 from:<dir-ino(73433017)> ⧗persisted> [duration 44ms798µs]
1601: 2026-09-26 11:16:34.993 E  fileproviderd[58721:a15012] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳8d4 ‼️  done executing <J1 ‼️  create-item(propagated:<memory dbver:1 domver:<nil>> requested:<p:root n:"m{4}y" dir dls child:65533 m:rwxl ct:1790006369.8802583 mt:1790006369.880991>) why:itemChangedRemotely sched:utility#1790006372.6156569 error:<NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}>> [duration 81ms955µs]
1632: 2026-09-26 11:16:35.001 E  fileproviderd[58721:a15012] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳8d6 ‼️  done executing <J2 ‼️  create-item(propagated:<skills dbver:2 domver:<nil>> requested:<p:root n:"s{4}s" dir dls child:65533 m:rwxl ct:1790006369.8803205 mt:1790006369.8803205>) why:itemChangedRemotely sched:utility#1790006372.6156569 error:<NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}>> [duration 97ms149µs]
```

## fp-namespace-retry.log
```text
15: 2026-09-26 11:29:36.622 Df fileproviderd[58721:a20302] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳1195 ✅  done executing <J1 ⏳  create-item(propagated:<memory dbver:2 domver:<nil>> requested:<p:root n:"m{4}y" dir dls child:65533 m:rwxel ct:1790006369.8802583 mt:1790006369.880991>) why:itemChangedRemotely sched:utility#1790006372.6156569 from:<dir-ino(73446037)> ⧗persisted> [duration 1s699ms]
23: 2026-09-26 11:29:36.688 Df fileproviderd[58721:a20306] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳1196 ✅  done executing <J2 ⏳  create-item(propagated:<skills dbver:3 domver:<nil>> requested:<p:root n:"s{4}s" dir dls child:65533 m:rwxel ct:1790006369.8803205 mt:1790006369.8803205>) why:itemChangedRemotely sched:utility#1790006372.6156569 from:<dir-ino(73446045)> ⧗persisted> [duration 1s765ms]
29: 2026-09-26 11:29:36.907 E  fileproviderd[58721:a20306] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳11cf ‼️  done executing <J1 ‼️  create-item(propagated:<memory dbver:2 domver:<nil>> requested:<p:root n:"m{4}y" dir dls child:65533 m:rwxel ct:1790006369.8802583 mt:1790006369.880991>) why:itemChangedRemotely sched:utility#1790006372.6156569 error:<NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}>> [duration 116ms587µs]
55: 2026-09-26 11:29:36.996 E  fileproviderd[58721:a20306] [com.apple.FileProvider:com.openminis.app.FileProvider/c{15}p.files] ┳11d1 ‼️  done executing <J2 ‼️  create-item(propagated:<skills dbver:3 domver:<nil>> requested:<p:root n:"s{4}s" dir dls child:65533 m:rwxel ct:1790006369.8803205 mt:1790006369.8803205>) why:itemChangedRemotely sched:utility#1790006372.6156569 error:<NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}>> [duration 187ms659µs]
```

## iOS26已有安装的系统dump（节选）
```text
    + scheduling state: running
      i:memory create-item: 🛑 last:'1790393001 (-2s450ms)' next:'1790393023 (19s52ms)' count:4 error:'NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}' domain:none category:<nil> prio:utility
      i:skills create-item: 🔶 last:'1790392992 (-11s321ms)' expired:'1790393002 (-1s822ms)' count:3 error:'NSError: POSIX 1 "未能完成该操作。操作不被允许" Underlying={NSError: libfssync.DocumentWharfError 4 "cannotCreate(Optional(FileProviderDaemon.VFSFileError.cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))))" Underlying={NSError: libfssync.VFSFileError 22 "cannotSetMetadata(__C.FPFSSetMetadataFlags(rawValue: 8119226119), failed: __C.FPFSSetMetadataFlags(rawValue: 8085606151))" UserInfo={(omitted)}}}}}' domain:none category:<nil> prio:utility
```
