local _ = require("gettext")
return {
    fullname = _("学习助理"),
    description = _([[小学到高中多学科答题练习与背诵，支持多省/多教材、知识点学习、英语单词默写、星星积分、连续打卡、奖章、错题本和可选 AI 变种强化。]]),
    -- Single source of truth for the plugin version. GitHub Release tags use
    -- "v" .. version (e.g. v1.3.0) and carry a studyassist.koplugin.zip asset.
    version = "1.20.3",
}
