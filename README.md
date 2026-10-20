# DjiCanDoBetter
以Json文件的形式提供错误码/HMS/固件包信息/相机传感器信息等开发资源，无需鉴权也可以拉取，方便开发者及时同步最新信息、进行大疆机场相关的开发。

## 当前支持开发资源
### 错误码

本项目中汇总的错误信息中包含`含义`/`描述`/`问题可能原因`等信息。见 [错误码](./error_code/codes.json) 

整体而言，错误码为 "ABCDEF" 格式，A 说明上报来源，BC 说明功能模块，DEF 为模块自定义错误。

按照 [OpenAPI 2.0私有化](https://henvmbbf6x.apifox.cn/8983516m0) 中的描述，错误码段位与业务域关系应当如下：

| 段位            | 业务域                                             |
| --------------- | -------------------------------------------------- |
| 200xxx          | 通用 / 鉴权                                        |
| 210xxx          | 组织 / 项目 / 用户 / 角色权限                      |
| 212xxx          | 设备 IoT 通用（设备离线、指令超时等）              |
| 213xxx          | 直播 / 旁路推流 / 录制（云端 / 设备端 / Pilot 端） |
| 214xxx          | 航线 / 飞行任务                                    |
| 217xxx          | 航线 / 飞行任务                                    |
| 219xxx          | 航线 / 飞行任务                                    |
| 223xxx          | 媒体变化检测 / 开放建模                            |
| 225xxx          | 飞行区 / 地形障碍物 / 自定义飞行区同步             |
| 228xxx          | 实时控制 / DRC 控制权 / 飞行控制                   |
| 229xxx          | RTK / 激活                                         |
| 230xxx          | 飞行区 / 地形障碍物 / 自定义飞行区同步             |
| 231xxx          | 分享（媒体 / 直播分享）                            |
| 233xxx          | 直播参数配置                                       |
| 238xxx          | AI 算法 / AI Link                                  |
| 239xxx          | AI 算法 / AI Link                                  |
| 241xxx ~ 246xxx | 文件同步 / SSO                                     |
| 312xxx ~ 327xxx | 设备升级 / 飞行执行 / 机场 / 相机控制 / 增强图传   |
| 341xxx ~ 400xxx | RTK 标定 / 设备 SN                                 |
| 513xxx          | 直播 / 旁路推流 / 录制（云端 / 设备端 / Pilot 端） |
| 514xxx          | 机场 / DRC 网关 / 网络                             |
| 613xxx          | 直播 / 旁路推流 / 录制（云端 / 设备端 / Pilot 端） |

但是在[上云API 2.0](https://developer.dji.com/doc/cloud-api-2-tutorial/cn/error-codes.html) 文档中，错误码的业务域和错误归类存在无法统一的情况，例如：219xxx既有属于`计划库`的错误归类(如：219004)，又有属于`移动部署`的错误归类(如：219036)，还有`机场远程升级`(如：219012) 和`指令飞行` (如：219031)的错误归类，无法统一到`航线 / 飞行任务` 的业务域。

因此，本项目的错误码中目前没有计划支持`业务域`或`错误归类`。

当前错误码的来源中，包括但不限于：

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
* 大疆智图API(当前已从开发者网站下架，无法访问)
* ……




### HMS健康告警 

HMS功能是为了设备的问题能在云端显示，提升用户对于风险的感知和处理能力，以保障作业安全。

当前存在的问题：错误码不全，一些已公开的常见HMS提示长期未收录进官方文档中。

本项目对HMS健康告警文件按设备类型了整理，见：

* [机场](./hms/dock.json)
* [无人机](./hms/fpv.json)
* [机库（无网关功能的机场，如:大疆机场4）](./hms/hangar.json)
* [外置电源](./hms/power.json)
* [中继/基站](./hms/relay.json)

来源包含并不限于：

* [上云API 1.0](https://terra-1-g.djicdn.com/fee90c2e03e04e8da67ea6f56365fc76/SDK%20%E6%96%87%E6%A1%A3/CloudAPI/hms.json)
* [大疆论坛](https://sdk-forum.dji.net/hc/zh-cn/categories/900001352083--上云API)
* [大疆运载云端互联](https://terra-1-g.djicdn.com/28a68761a34f4df3b477d3cfca12eea2/SDK/drone-hms.json)
* ……

### 固件发布记录

为了保证大疆机场和飞行器的稳定运行，降低事故发生率，DJI 强烈建议在每次有新固件发布时，积极鼓励客户升级到最新的机场/飞行器固件。

然而有些固件并不稳定，存在各种各样的问题，导致平台端被动发布补丁进行修复，影响平台发布节奏；某些问题无法及时解决、甚至无法在平台端解决，只能等待后续版本修复。

为此，本项目中汇总了以下设备的最新固件和历史固件，方便开发者在遇到严重问题时，能够回退固件版本。

* [Dock1](./firmware/3-1-0.json)
* [Dock2](./firmware/3-2-0.json)
* [Dock3](./firmware/3-3-0.json)
* [M30](./firmware/0-67-0.json)
* [M30T](./firmware/0-67-1.json)
* [M3D](./firmware/0-91-0.json)
* [M3TD](./firmware/0-91-1.json)
* [M4D](./firmware/0-100-0.json)
* [M4TD](./firmware/0-100-1.json)
* [D-RTK 3](./firmware/6-600-0.json)

本项目仅提供`文件下载地址`、`MD5`等必要信息；不提供具体固件文件。

### 相机传感器信息

大疆技术支持提供了各设备相机传感器尺寸、像元大小、照片分辨率和真实焦距信息。

本项目中，真实记录了大疆提供的信息，并使用大模型根据传感器尺寸对FOV进行推演，结果如下：

* [M30相机](./sensor/52-0-0.json)
* [M30T相机](./sensor/53-0-0.json)
* [M3D相机](./sensor/80-0-0.json)
* [M3TD相机](./sensor/81-0-0.json)
* [M4D相机](./sensor/98-0-0.json)
* [M4TD相机](./sensor/99-0-0.json)

**特别声明**：相机传感器相关知识触及我的知识盲区，因此无法对大模型分析结果进行校对。推演结果与大疆技术参数有出入，请谨慎使用。如有相关行业大佬，欢迎审阅并指正。

```json
{
    "device_model": "53-0-0",// 相机编码
    "device_name": "Matrice 30T Camera",// 相机名称
    "product_page": "https://enterprise.dji.com/cn/matrice-30/specs",// 相机部分技术参数
    "sensor": [// 传感器信息
        {
            "type": "wide",// 相机类型
            "desc": "广角",// 相机描述
            "sensor_size": {// 传感器尺寸信息
                "width": 6.4,
                "height": 4.8,
                "unit": "mm"
            },
            "pixel_size": {// 像元大小
                "width": 1.6,
                "height": 1.6,
                "unit": "µm"
            },
            "photo_resolution": [// 照片分辨率
                {
                    "width": 4000,
                    "height": 3000,
                    "unit": "px"
                }
            ],
            "real_focal_length": {// 真实焦距
                "max": 4.5,
                "min": 4.5,
                "unit": "mm"
            },
            "fov": [// FOV（推算值）
                {
                    "factor": 1.0,// 光学变焦倍数
                    "dfov": 83.27,// 对角线FOV（下同）
                    "hfov": 70.83,// 水平FOV（下同）
                    "vfov": 56.14,// 垂直FOV（下同）
                    "unit": "°"
                }
            ],
            "equivalent_focal_length": {// 等效焦距（推算值）
                "max": 24.34,
                "min": 24.34,
                "unit": "mm"
            }
        },
        {
            "type": "zoom",// 相机类型
            "desc": "变焦",// 相机描述
            "sensor_size": {// 传感器尺寸信息
                "width": 6.4,
                "height": 4.8,
                "unit": "mm"
            },
            "pixel_size": {// 像元大小
                "width": 1.6,
                "height": 1.6,
                "unit": "µm"
            },
            "photo_resolution": [// 照片分辨率
                {
                    "width": 4000,// 大疆技术支持提供了两种分辨率，此处可能为普通模式下的分辨率
                    "height": 3000,
                    "unit": "px"
                },
                {
                    "width": 8000,// 大疆技术支持提供了两种分辨率，此处可能为超分模式下的分辨率
                    "height": 6000,
                    "unit": "px"
                }
            ],
            "real_focal_length": {// 真实焦距
                "max": 75,
                "min": 21,
                "unit": "mm"
            },
            "fov": [// FOV（推算值）
                {
                    "factor": 4.67,// 光学变焦倍数。M30系列变焦相机为连续光学变焦，此处为最小倍数时FOV大小
                    "dfov": 21.57,
                    "hfov": 17.33,
                    "vfov": 13.04,
                    "unit": "°"
                },
                {
                    "factor": 16.67,// 光学变焦倍数。M30系列变焦相机为连续光学变焦，此处为最大倍数时FOV大小
                    "dfov": 6.11,
                    "hfov": 4.89,
                    "vfov": 3.67,
                    "unit": "°"
                }
            ],
            "equivalent_focal_length": {// 等效焦距（推算值）
                "max": 405.62,
                "min": 113.58,
                "unit": "mm"
            }
        },
        {
            "type": "ir",// 相机类型
            "desc": "红外",// 相机描述
            "sensor_size": {// 传感器尺寸
                "width": 7.68,
                "height": 6.144,
                "unit": "mm"
            },
            "pixel_size": {// 像元大小
                "width": 12,
                "height": 12,
                "unit": "µm"
            },
            "photo_resolution": [// 照片分辨率
                {
                    "width": 640,
                    "height": 512,
                    "unit": "px"
                }
            ],
            "real_focal_length": {// 真实焦距
                "max": 9.1,
                "min": 9.1,
                "unit": "mm"
            },
            "fov": [// FOV（推算值）
                {
                    "factor": 2.02,// 光学变焦倍数
                    "dfov": 56.77,
                    "hfov": 45.76,
                    "vfov": 37.31,
                    "unit": "°"
                }
            ],
            "equivalent_focal_length": {// 等效焦距（推算值）
                "max": 40.03,
                "min": 40.03,
                "unit": "mm"
            }
        }
    ]
}
```


### 未来计划支持的开发资源
* 踩坑记录（常见问题和排障方案）
* 设备属性
* 文档中遗漏的各类枚举值
* 补全大疆4代机场相关信息

### 其他
欢迎提交必要需求。

若文档有疏漏或错误，欢迎指正！

欢迎协作！