--[[--
Star shop ("星星商城") and the wallet that keeps the redeemed 卡券.

Stars earned by answering questions are the currency. Parents stock the shop
with 卡券 (wish-list coupons the child really wants: "看 30 分钟动画片" for 30
stars, "买一本想要的书" for 100 stars ...). The child redeems one with stars;
the coupon lands in the wallet and stays 待兑现 until a parent hands over the
real thing — cashing it in needs the 4-digit exit password, so the child cannot
"spend" a coupon on their own.

All state travels with the save file under progress.data.shop:

    shop.items    = { { id, name, cost, enabled }, ... }  -- 家长维护的商品
    shop.redeemed = { { id, item_id, name, cost, at, cashed, cashed_at }, ... }
    shop.spent    = 已花掉的星星（余额 = 累计星星 total.points - spent）

`total.points` stays the lifetime total so badges and stats never go backwards.
--]]--

local Shop = {}

-- 预置愿望清单：家长不用在 Kindle 上打中文就能直接开张，之后可以改价、下架或删除。
Shop.DEFAULT_ITEMS = {
    { id = "cartoon30", name = "看 30 分钟动画片", cost = 20 },
    { id = "story1", name = "睡前多讲一个故事", cost = 15 },
    { id = "dinner", name = "周末选一次想吃的", cost = 30 },
    { id = "game20", name = "玩 20 分钟游戏", cost = 30 },
    { id = "chore1", name = "免做一次家务", cost = 40 },
    { id = "movie", name = "全家看一部电影", cost = 50 },
    { id = "book1", name = "买一本想要的书", cost = 100 },
    { id = "park1", name = "去一次公园或游乐场", cost = 150 },
}

local MAX_NAME_BYTES = 60 -- 约 20 个汉字，够写清一张卡券
local MAX_COST = 9999

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--[[--
Create / repair the shop tables on a progress data table. Called from
Progress:normalize so old saves get the default wish list once and parents'
edits are never overwritten afterwards.
--]]--
function Shop.ensure(data)
    if type(data) ~= "table" then return nil end
    local shop = data.shop
    if type(shop) ~= "table" then
        shop = {}
        data.shop = shop
    end
    if type(shop.items) ~= "table" then shop.items = {} end
    if type(shop.redeemed) ~= "table" then shop.redeemed = {} end
    shop.spent = tonumber(shop.spent) or 0
    shop.next_id = tonumber(shop.next_id) or 0
    shop.next_record = tonumber(shop.next_record) or #shop.redeemed

    if not shop.seeded then
        -- 首次升级：只在商城还是空的时候铺上预置清单，绝不覆盖家长已有的编辑。
        if #shop.items == 0 then
            for _, item in ipairs(Shop.DEFAULT_ITEMS) do
                table.insert(shop.items, {
                    id = item.id, name = item.name, cost = item.cost, enabled = true,
                })
            end
        end
        shop.seeded = true
    end

    -- 清洗脏数据（手改过存档、或旧版本字段缺失），倒序删不会打乱下标
    local seen = {}
    for i = #shop.items, 1, -1 do
        local item = shop.items[i]
        local bad = type(item) ~= "table"
            or type(item.name) ~= "string" or trim(item.name) == ""
            or type(item.cost) ~= "number" or item.cost < 1
        -- 注意：item.id 可能是 nil，直接拿它下标会抛错，先判类型再查重
        if not bad and type(item.id) == "string" and seen[item.id] then bad = true end
        if bad then
            table.remove(shop.items, i)
        else
            item.cost = math.floor(math.min(item.cost, MAX_COST))
            item.enabled = item.enabled ~= false
            if type(item.id) ~= "string" or item.id == "" then
                shop.next_id = shop.next_id + 1
                item.id = "u" .. shop.next_id
            end
            seen[item.id] = true
        end
    end
    for i = #shop.redeemed, 1, -1 do
        local record = shop.redeemed[i]
        if type(record) ~= "table" or type(record.name) ~= "string" then
            table.remove(shop.redeemed, i)
        else
            record.cost = tonumber(record.cost) or 0
            record.at = tonumber(record.at) or 0
            record.cashed = record.cashed == true
            if type(record.id) ~= "string" or record.id == "" then
                shop.next_record = shop.next_record + 1
                record.id = "r" .. shop.next_record
            end
        end
    end
    return shop
end

-- 可用星星 = 累计获得 - 已兑换花掉的
function Shop.balance(progress)
    local data = progress and progress.data or {}
    local total = data.total and data.total.points or 0
    local shop = Shop.ensure(data)
    return math.max(0, math.floor(total - (shop and shop.spent or 0)))
end

function Shop.spent(progress)
    local shop = Shop.ensure(progress.data)
    return shop and math.floor(shop.spent) or 0
end

function Shop.find(progress, item_id)
    local shop = Shop.ensure(progress.data)
    for _, item in ipairs(shop.items) do
        if item.id == item_id then return item end
    end
    return nil
end

-- 在售商品：先按星星数从少到多，同价按名字
function Shop.items(progress)
    local shop = Shop.ensure(progress.data)
    local list = {}
    for _, item in ipairs(shop.items) do
        if item.enabled then table.insert(list, item) end
    end
    table.sort(list, function(a, b)
        if a.cost == b.cost then return a.name < b.name end
        return a.cost < b.cost
    end)
    return list
end

-- 家长管理页用：全部商品，上架的和下架的都在
function Shop.all_items(progress)
    local shop = Shop.ensure(progress.data)
    return shop.items
end

function Shop.redeem(progress, item_id)
    local item = Shop.find(progress, item_id)
    if not item then return nil, "这件商品已经下架了" end
    if not item.enabled then return nil, "这件商品已经下架了" end
    local balance = Shop.balance(progress)
    if balance < item.cost then
        return nil, string.format("还差 %d 颗星星", item.cost - balance)
    end
    local shop = Shop.ensure(progress.data)
    shop.spent = shop.spent + item.cost
    shop.next_record = shop.next_record + 1
    local record = {
        id = "r" .. shop.next_record,
        item_id = item.id,
        name = item.name,
        cost = item.cost,
        at = os.time(),
        cashed = false,
    }
    table.insert(shop.redeemed, record)
    progress:flush()
    return record
end

-- 已兑换的卡券，新的排前面
function Shop.redeemed(progress)
    local shop = Shop.ensure(progress.data)
    local list = {}
    for i = #shop.redeemed, 1, -1 do
        table.insert(list, shop.redeemed[i])
    end
    return list
end

function Shop.find_record(progress, record_id)
    local shop = Shop.ensure(progress.data)
    for _, record in ipairs(shop.redeemed) do
        if record.id == record_id then return record end
    end
    return nil
end

function Shop.pending_count(progress)
    local count = 0
    for _, record in ipairs(Shop.redeemed(progress)) do
        if not record.cashed then count = count + 1 end
    end
    return count
end

-- 家长兑现：把卡券标记成已兑现（调用方必须先校验家长密码）
function Shop.cash(progress, record_id)
    local record = Shop.find_record(progress, record_id)
    if not record then return nil, "找不到这张卡券" end
    if record.cashed then return nil, "这张卡券已经兑现过了" end
    record.cashed = true
    record.cashed_at = os.time()
    progress:flush()
    return record
end

function Shop.add_item(progress, name, cost)
    name = trim(name)
    if name == "" then return nil, "请输入商品名称" end
    if #name > MAX_NAME_BYTES then return nil, "名称太长，请控制在 20 个字以内" end
    local price = tonumber(cost)
    if not price or price ~= price then return nil, "星星数请填数字" end
    price = math.floor(price)
    if price < 1 then return nil, "星星数要大于 0" end
    if price > MAX_COST then return nil, string.format("星星数最多 %d", MAX_COST) end
    local shop = Shop.ensure(progress.data)
    for _, item in ipairs(shop.items) do
        if trim(item.name) == name then
            item.cost = price
            item.enabled = true
            progress:flush()
            return item, nil, true
        end
    end
    shop.next_id = shop.next_id + 1
    local item = { id = "u" .. shop.next_id, name = name, cost = price, enabled = true }
    table.insert(shop.items, item)
    progress:flush()
    return item, nil, false
end

function Shop.remove_item(progress, item_id)
    local shop = Shop.ensure(progress.data)
    for i, item in ipairs(shop.items) do
        if item.id == item_id then
            table.remove(shop.items, i)
            progress:flush()
            return true
        end
    end
    return false
end

-- 改价：家长在商城后台点一下卡片就能重设星星数。只动这一件商品；
-- 钱包里的兑换记录存的是当时的名称与花费，不会被改价回溯。
function Shop.set_cost(progress, item_id, cost)
    local item = Shop.find(progress, item_id)
    if not item then return nil, "商品已经不在了" end
    local price = tonumber(cost)
    if not price or price ~= price then return nil, "星星数请填数字" end
    price = math.floor(price)
    if price < 1 then return nil, "星星数要大于 0" end
    if price > MAX_COST then return nil, string.format("星星数最多 %d", MAX_COST) end
    item.cost = price
    progress:flush()
    return item
end

-- 上架 / 下架。下架只是从孩子那端隐藏，已兑换的卡券不受影响。
function Shop.set_enabled(progress, item_id, enabled)
    local item = Shop.find(progress, item_id)
    if not item then return nil end
    item.enabled = enabled and true or false
    progress:flush()
    return item
end

return Shop
