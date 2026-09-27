# 26-09-26 修复 TestFlight 备用图标尺寸警告

状态：completed（已验收并按用户要求归档）
更新：2026-09-27

## 确认与范围

用户在当前对话提供1.13（2）上传警告截图并要求“解决一下这个问题”，直接授权修复90890/90892备用图标缺少120、152、167像素的问题。沿用/Users/huyuanzhao/Coding/Projects/OpenMinis的feat/chat-context-usage分支，保留已有未提交修改。此为已有TestFlight发布流程的局部资源/打包修复，未修改应用行为、图案、版本、签名或测试用户范围；不上传、不安装到设备、不提交合并。

## 实现与验收

四个备用图标原先仅有1024像素普通PNG，Info.plist手工注册路径，不经actool生成各设备尺寸。复制原始无透明PNG到同名appiconset，保留原路径供设置预览使用；Debug/Release显式指定Alternate App Icon Sets。移除手工CFBundleIcons及iPad字典，由编译器统一生成主/备用图标声明。切换图标的四个名称不变。

验收：原图逐字节一致；生成的iPhone/iPad元数据通过CFBundleIconName指向实际编译资源，不再通过CFBundleIconFiles引用缺少尺寸的普通PNG；本地Release构建检查打包结果。初始预期编译器会写出所有小尺寸独立PNG，实测Xcode 27的Single Size方式将1024图标存入Assets.car，系统据此提供各尺寸（Apple官方Configuring your app icon using an asset catalog说明支持Single Size），因此按实际受支持的资源目录路径验证，不宣称包内有四组独立小尺寸PNG。达到本地验证后停止，不扩展到设备/后台操作。Apple服务器警告是否消失需下次上传确认，不能以本地验证替代。

## 审查与验证

actool针对iphoneos、iOS26、iphone/ipad编译通过。原图四份与资源目录输入逐字节一致；八个设备注册名称均能在Assets.car中解析为1024x1024 Icon Image。证据outputs/icon-upload-validation/catalog-assertions.json（当前对话工作目录下）。Release归档已完成，见下方最终验证。适用规则AGENTS.md；参考Apple Configuring your app to use alternate app icons与QA1686。代码变更限图标目录、Info.plist和两处构建设置。


## 最终验证与下一步

Release iphoneos归档成功（Xcode 27，generic/platform=iOS，CODE_SIGNING_ALLOWED=NO），未签名、未上传、未安装设备。归档内com.yyzzzor.minisx、1.13（2）与当前源码一致；未修改用户已经设置的Build 2。主图标及四种备用图标在iPhone/iPad均有CFBundleIconName且指向Assets.car内实际Icon Image，四种备用图标均无旧CFBundleIconFiles普通路径。设置页使用的四份原始PNG在归档中逐字节保留。git diff --check通过。

证据：evidence/archive-assertions.json、archive-icons.plist、catalog-assertions.json。完整构建日志及未签名归档位于当前对话outputs/icon-upload-validation/archive.log与MinisX-icon-fix.xcarchive。此归档用于本地包内容验证，不可直接作为已签名上传产物；签名、服务端处理及真机切图标未在本轮执行。

下一步：需要更新TestFlight时，将主应用和扩展Build统一提高到3或后台尚未使用的更高编号，重新Archive并签名上传，确认90890/90892不再出现。已上传1.13（2）的记录不会被本地改动替换。在上传验证前不将服务端验收标记完成，不提交/合并/归档本任务。

官方依据：
- https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons （由Alternate App Icon Sets生成CFBundleAlternateIcons）。
- https://developer.apple.com/documentation/xcode/configuring-your-app-icon （iOS/iPadOS支持单张1024图标自动提供各尺寸变体）。


## 本地提交状态更新（2026-09-27）

用户在同一对话授权“把可以提交的东西提交”，同时明确任务不归档，以便继续添加自己的理解性注释。图标修复已本地提交为d910292；Build 2及发布状态另存为000c5f5。本次授权只取代上文历史阶段“不提交”的约束，上传验证仍待下一构建，任务继续active，不合并、不推送、不归档。


同日撤回功能提交后的更新：上下文实现已按用户要求恢复为未提交改动；图标修复与版本记录仍保留在本地提交中，重新生成的提交号分别为fcb8586、b6ee114。图标任务仍active，上传验证边界不变。


## 审查目录标题整理（2026-09-27）

根据维护者要求，将本任务reviews下的纯序号目录改为“序号＋具体审查主题”。[审查目录索引](reviews/README.md)保留旧名与新名对照；所有原始材料及附件搬迁前后SHA-256一致，未修改原始请求、报告、manifest或快照中的历史路径。本轮只调整命名和当前入口，不改变审查结论，任务仍active。


## 本轮提交与归档条件核对（2026-09-27）

维护者要求提交未提交工作后评估归档条件；本轮只提交审查目录标题整理及记录，未修改图标源码。逐字节对照HEAD确认迁移后的7份原已跟踪审查材料一致。

归档判断：暂不能确认完成。本地资源及Release归档包检查已通过，但尚无修复版上传Apple后90890/90892警告消失的证据。当前主应用及扩展Build 3已由5e5e2da提交；上文“提高到3”的下一步已完成源码设置，不代表实际签名上传。下一步是上传时核对后台可用构建号、重新签名归档并确认服务端警告结果；本轮不执行上传，不归档、合并或推送。


## 用户确认上传结果与最终验收（2026-09-27）

在主Agent说明本任务仍缺“修复版上传Apple后90890/90892警告消失”的确认后，维护者明确反馈：“第二个任务在提交后，没有再出现类似的警告了”。据此记录上传结果已由维护者确认，补齐本任务最后的验收项；结合已有本地资源、Release归档包检查及独立审查处理，图标尺寸警告修复验收完成，可以归档。

此结论来自维护者反馈，非Agent本轮重新上传或读取Apple后台所得；本次反馈未提供具体构建号，不推定为某个版本。上文“待上传确认”“暂不能确认完成”为此前阶段记录，由本节结论取代。当前请求是确认哪些任务可归档，因此先保留原目录；不自动归档、合并或推送。


## 归档（2026-09-27）

维护者明确要求“第二个任务归档吧”。本任务验收已完成，现将任务、检查点、审查记录和附件整体移至 tasks/archive，名称保持不变。原始审查材料及检查点原字节保留；检查点代表归档前状态，不改写为归档后match。本次只归档图标修复任务；上下文指示器任务继续active，未合并、推送。
