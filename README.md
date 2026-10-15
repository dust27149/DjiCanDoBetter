# DjiCanDoBetter
以Json文件的形式提供错误码/HMS/固件包信息等开发资源，无需鉴权也可以拉取，方便开发者及时同步最新信息、进行大疆机场相关的开发。

## 当前支持开发资源
### 错误码

见 [错误码](./error_code/codes.json) 

当前汇总了多个来源的错误码，包括但不限于：

* [上云API 1.0](https://developer.dji.com/doc/cloud-api-tutorial/cn/error-code.html)
* [上云API 2.0](https://developer.dji.com/doc/cloud-api-2-tutorial/cn/error-codes.html)
* [HMS](https://terra-1-g.djicdn.com/fee90c2e03e04e8da67ea6f56365fc76/SDK%20%E6%96%87%E6%A1%A3/CloudAPI/hms.json) 中328xx和332xx相关错误码
* [大疆司空](https://fh.dji.com/user-manual/cn/organization-management/device-management.html#云服务切换)
* [大疆司运](https://2rybwyrrk6.apifox.cn/doc-3990540)
* [大疆论坛](https://sdk-forum.dji.net/hc/zh-cn/articles/33865335025945)
* [OpenAPI 1.0公有云](https://fh2-api.apifox.cn/doc-7183966)
* [OpenAPI 2.0公有云](https://s.apifox.cn/4de4a239-c2cc-4572-9b65-90738289f37a/8785335m0)
* [OpenAPI 2.0私有化](https://henvmbbf6x.apifox.cn/8983516m0)
* [用爱发电社区](https://www.kdocs.cn/l/clOp5VzfiTYE) 感谢 `奔波儿小马@BoermaPony` 等人的奉献！
* ……

错误信息中包含`含义`/`描述`/`问题可能原因`等信息。目前没有计划支持`错误归类`。

### HMS健康告警 

HMS健康告警文件已按设备类型整理，见：

* [机场](./hms/dock.json)
* [无人机](./hms/fpv.json)
* [机库](./hms/hangar.json)
* [外置电源](./hms/power.json)
* [中继/基站](./hms/relay.json)

来源包含并不限于：

* [上云API 1.0](https://terra-1-g.djicdn.com/fee90c2e03e04e8da67ea6f56365fc76/SDK%20%E6%96%87%E6%A1%A3/CloudAPI/hms.json)
* [大疆论坛](https://sdk-forum.dji.net/hc/zh-cn/categories/900001352083--上云API)
* [大疆运载云端互联](https://terra-1-g.djicdn.com/28a68761a34f4df3b477d3cfca12eea2/SDK/drone-hms.json)
* ……

### 固件发布记录

当前汇总了以下设备的固件，来源于大疆官网。

* [Dock1](./firmware/3-1-0.json)
* [Dock2](./firmware/3-2-0.json)
* [Dock3](./firmware/3-3-0.json)
* [M30](./firmware/0-67-0.json)
* [M30T](./firmware/0-67-1.json)
* [M3D](./firmware/0-91-0.json)
* [M3TD](./firmware/0-91-1.json)
* [M4D](./firmware/0-100-0.json)
* [M4TD](./firmware/0-100-1.json)

仅提供`文件下载地址`、`MD5`等必要信息。不提供具体固件文件。

除Dock3/M4D/M4TD提供了历史固件外，其余设备只提供了最后发布的固件。未来计划完善到对应主版本的最早的固件。

### 未来计划支持的开发资源
* 踩坑记录（常见问题和排障方案）
* 机型GSD信息
* 设备属性
* 文档中遗漏的各类枚举值

### 其他
欢迎提交必要需求。

若文档有疏漏或错误，欢迎指正！

欢迎协作！