describe("StudyAssist star shop", function()
    local Shop

    setup(function()
        package.path = "plugins/studyassist.koplugin/?.lua;" .. package.path
        Shop = require("core.shop")
    end)

    -- 纯数据替身：Shop 只碰 progress.data 与 progress:flush()
    local function progress(points, shop)
        return {
            data = { total = { points = points or 0 }, shop = shop },
            flushes = 0,
            flush = function(self) self.flushes = self.flushes + 1 end,
        }
    end

    local function find(list, id)
        for _, item in ipairs(list) do
            if item.id == id then return item end
        end
    end

    it("seeds the default wish list once and keeps later edits", function()
        local p = progress(0)
        local items = Shop.all_items(p)
        assert.are.equal(#Shop.DEFAULT_ITEMS, #items)
        assert.is_true(Shop.items(p)[1].cost <= Shop.items(p)[#Shop.items(p)].cost)

        -- 家长删掉一件后，再次 normalize 不会把它加回来
        Shop.remove_item(p, items[1].id)
        Shop.ensure(p.data)
        assert.are.equal(#Shop.DEFAULT_ITEMS - 1, #Shop.all_items(p))
    end)

    it("uses earned stars minus spent stars as the wallet balance", function()
        local p = progress(120)
        assert.are.equal(120, Shop.balance(p))
        local cheapest = Shop.items(p)[1]
        local record = Shop.redeem(p, cheapest.id)
        assert.is_not_nil(record)
        assert.are.equal(120 - cheapest.cost, Shop.balance(p))
        assert.are.equal(cheapest.cost, Shop.spent(p))
        -- 累计星星不动，只记花费
        assert.are.equal(120, p.data.total.points)
        assert.are.equal(1, p.flushes)
    end)

    it("refuses a coupon the child cannot afford yet", function()
        local p = progress(5)
        local most = Shop.items(p)[#Shop.items(p)]
        local record, err = Shop.redeem(p, most.id)
        assert.is_nil(record)
        assert.is_truthy(err:find("还差", 1, true))
        assert.are.equal(0, Shop.spent(p))
    end)

    it("parks a redeemed coupon in the wallet until a parent cashes it", function()
        local p = progress(100)
        local item = Shop.items(p)[1]
        local record = Shop.redeem(p, item.id)
        assert.is_false(record.cashed)
        assert.are.equal(1, Shop.pending_count(p))
        assert.are.equal(record.id, Shop.redeemed(p)[1].id)

        local cashed = Shop.cash(p, record.id)
        assert.is_true(cashed.cashed)
        assert.is_truthy(cashed.cashed_at)
        assert.are.equal(0, Shop.pending_count(p))

        local again, err = Shop.cash(p, record.id)
        assert.is_nil(again)
        assert.is_truthy(err)
    end)

    it("adds a parent-defined coupon and updates its price on a duplicate name", function()
        local p = progress(0)
        local before = #Shop.all_items(p)
        local item, err, existed = Shop.add_item(p, "  周末去骑车  ", "35")
        assert.is_not_nil(item)
        assert.is_nil(err)
        assert.is_false(existed)
        assert.are.equal("周末去骑车", item.name)
        assert.are.equal(35, item.cost)
        assert.are.equal(before + 1, #Shop.all_items(p))

        local same, _, existed2 = Shop.add_item(p, "周末去骑车", 50)
        assert.is_true(existed2)
        assert.are.equal(50, same.cost)
        assert.are.equal(before + 1, #Shop.all_items(p))

        assert.is_nil(Shop.add_item(p, "  ", 10))
        assert.is_nil(Shop.add_item(p, "零花钱", 0))
        assert.is_nil(Shop.add_item(p, "零花钱", "abc"))
    end)

    it("hides an off-shelf coupon from the child but keeps redeemed records", function()
        local p = progress(100)
        local item = Shop.items(p)[1]
        Shop.redeem(p, item.id)
        Shop.set_enabled(p, item.id, false)
        assert.is_nil(find(Shop.items(p), item.id))
        assert.is_not_nil(find(Shop.all_items(p), item.id))
        assert.are.equal(1, #Shop.redeemed(p))

        Shop.remove_item(p, item.id)
        assert.is_nil(find(Shop.all_items(p), item.id))
        assert.are.equal(1, #Shop.redeemed(p))
    end)

    it("repairs hand-edited saves without dropping valid rows", function()
        local p = progress(40, {
            seeded = true,
            items = {
                { name = "没有 id", cost = 10 },
                { id = "dup", name = "先来的", cost = 20 },
                { id = "dup", name = "后来的", cost = 25 },
                { id = "bad", name = "", cost = 30 },
                { id = "neg", name = "负价", cost = -1 },
            },
            redeemed = { { name = "旧卡券", cost = 10, at = 1 } },
            spent = 10,
        })
        local items = Shop.all_items(p)
        -- 5 行脏数据：无 id 补 id 保留；两条 dup 只留后一条；空名与负价删除
        assert.are.equal(2, #items)
        assert.is_nil(find(items, "bad"))
        assert.is_nil(find(items, "neg"))
        assert.are.equal(25, find(items, "dup").cost)
        assert.are.equal(30, Shop.balance(p))
        assert.is_not_nil(Shop.redeemed(p)[1].id)
    end)
end)
