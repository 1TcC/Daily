#!/usr/bin/env python3
"""生成「Daily 短信投递」快捷指令：短信命中关键词时，把正文 POST 到中转服务的只写地址。

用法：python3 tools/make_sms_shortcut.py <短信接收地址> <输出 .shortcut 路径>
生成的是未签名文件，需要再用 `shortcuts sign` 签名后导入。
"""
import plistlib
import sys
import uuid

# 只有命中这些关键词的短信才会离开手机（验证码、银行、聊天都不匹配）
PATTERN = r"取件|取货|提货|取出|签收|包裹|快递|驿站|丰巢|自提点|铁路客服|12306|改签|退票|航班|值机|登机"


def token_string(text=None, input_attachment=False):
    """快捷指令里的文本参数；input_attachment=True 时是「快捷指令输入」变量。"""
    if input_attachment:
        value = {"string": "￼", "attachmentsByRange": {"{0, 1}": {"Type": "ExtensionInput"}}}
    else:
        value = {"string": text}
    return {"Value": value, "WFSerializationType": "WFTextTokenString"}


def dictionary(items):
    return {
        "Value": {
            "WFDictionaryFieldValueItems": [
                {"WFItemType": 0, "WFKey": token_string(k), "WFValue": v} for k, v in items
            ]
        },
        "WFSerializationType": "WFDictionaryFieldValue",
    }


def build(url):
    match_uuid = str(uuid.uuid4()).upper()
    group = str(uuid.uuid4()).upper()
    actions = [
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.text.match",
            "WFWorkflowActionParameters": {
                "UUID": match_uuid,
                "WFMatchTextPattern": PATTERN,
                "WFMatchTextCaseSensitive": False,
                "text": token_string(input_attachment=True),
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
            "WFWorkflowActionParameters": {
                "GroupingIdentifier": group,
                "WFControlFlowMode": 0,
                "WFCondition": 100,  # 有任何值
                "WFInput": {
                    "Type": "Variable",
                    "Variable": {
                        "Value": {"OutputUUID": match_uuid, "Type": "ActionOutput", "OutputName": "匹配"},
                        "WFSerializationType": "WFTextTokenAttachment",
                    },
                },
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.downloadurl",
            "WFWorkflowActionParameters": {
                "UUID": str(uuid.uuid4()).upper(),
                "WFURL": url,
                "WFHTTPMethod": "POST",
                "WFHTTPBodyType": "JSON",
                "WFJSONValues": dictionary([("text", token_string(input_attachment=True))]),
                "ShowHeaders": True,
                "WFHTTPHeaders": dictionary([("User-Agent", token_string("DailyShortcut/1.0"))]),
            },
        },
        {
            "WFWorkflowActionIdentifier": "is.workflow.actions.conditional",
            "WFWorkflowActionParameters": {"GroupingIdentifier": group, "WFControlFlowMode": 2},
        },
    ]
    return {
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "2607.0.0",
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowIcon": {"WFWorkflowIconStartColor": 4282601983, "WFWorkflowIconGlyphNumber": 59511},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
        "WFWorkflowHasShortcutInputVariables": True,
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": [],
        "WFQuickActionSurfaces": [],
    }


if __name__ == "__main__":
    url, out = sys.argv[1], sys.argv[2]
    with open(out, "wb") as f:
        plistlib.dump(build(url), f, fmt=plistlib.FMT_BINARY)
