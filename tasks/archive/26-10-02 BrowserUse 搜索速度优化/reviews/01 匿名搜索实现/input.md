# 匿名搜索实现审查输入

范围：本分支尚未提交的匿名`web_search`产品改动。
基线源码提交：`611dbfe`；七份原有Harness修改属于范围外。

规范：[匿名网页搜索S0–S9](../../../../../docs/specs/ios-web-search.md)、[统一网页读取W4、W5、R6](../../../../../docs/specs/ios-web-read.md)、[资源规范](../../../../../docs/specs/resource-efficiency.md)、[Debug API J2–J4](../../../../../docs/specs/debug-server-api.md)。

## 产品改动

- 新增WebSearchModels、WebSearchHTMLExtractor、WebSearchService。
- 修改WebReadDocumentStore、WebReadModels、WebReadURLSessionTransport及正文归档检查。
- 修改AIChatViewModel、ConcurrentTools、ToolDefinitions、BackgroundTask。
- 新增DEBUG直接搜索测试入口、Xcode引用及针对性测试。

## 目标与验收

搜索质量优先；当前页的有效标题、摘要和完整来源保留，长结果可以续读。
匿名HTTP成功路径不创建WebView或截图；不足时最多一次同引擎匿名渲染回退。
两个独立搜索共享全局上限，各自保留配对、取消及缓存范围。
原WebRead行为及原浏览器登录、接管保持正常。
具体十项验收见[任务](../../task.md#验收)。

## 已有验证与缺口

现有安装版本原问句已经重复3次，尚未构建新版本。
macOS六次Lite HTTP中两次取得结果、四次出现验证码，失败样本保留。
新代码的iOS测试、直接搜索和完整Agent对照待执行。
当前测试及DEBUG接入仍在补充，先审查核心产品逻辑，最终新增改动再复查。

## 审查要求

只报告影响正确性或违背需求的问题，写明规则、位置、触发及依据。
必须检查有界工作、主线程开销、取消、排队、缓存、共享WebKit预算及资源释放。
原始差异可用`git diff -- src/ios`查看；新增未跟踪文件需单独读取。
