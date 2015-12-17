function train_batch()
    -- start a new episode
    local batch = batch_init(g_opts.batch_size)
    local reward = {}
    local input = {}
    local action = {}
    local active = {}
    for t = 1, g_opts.max_steps do
        active[t] = batch_active(batch)
        if active[t]:sum() == 0 then break end
        input[t] = batch_input(batch, active[t], t)
        local out = g_model:forward(input[t])
        if not pcall(function() action[t] = torch.multinomial(torch.exp(out[1]), 1) end) then
            -- for some reason multinomial fails sometimes
            action[t] = torch.multinomial(torch.ones(out[1]:size()),1)
        end
        batch_act(batch, action[t]:view(-1), active[t])
        batch_update(batch, active[t])
        reward[t] = batch_reward(batch, active[t],t == g_opts.max_steps)
    end
    local success = batch_success(batch)
    if g_opts.curriculum == 1 then
        apply_curriculum(batch, success)
    end
    g_paramdx:zero()
    local stat = {}
    local R = torch.Tensor(g_opts.batch_size * g_opts.nagents):zero()
    for t = g_opts.max_steps, 1, -1 do
        if active[t] ~= nil and active[t]:sum() > 0 then
            local out = g_model:forward(input[t])
            R:add(reward[t])
            local baseline = out[2]
            baseline:cmul(active[t])
            R:cmul(active[t])
            stat.bl_cost = (stat.bl_cost or 0) + g_bl_loss:forward(baseline, R)
            stat.bl_count = (stat.bl_count or 0) + active[t]:sum()
            local bl_grad = g_bl_loss:backward(baseline, R):mul(g_opts.alpha)
            baseline:add(-1, R)
            local grad = torch.Tensor(g_opts.batch_size * g_opts.nagents, g_opts.nactions):zero()
            grad:scatter(2, action[t], baseline)
            grad:mul(g_opts.reinforce_coeff)
            grad:div(g_opts.batch_size)
            g_model:backward(input[t], {grad, bl_grad})
        end
    end

    R:resize(g_opts.batch_size, g_opts.nagents)
    -- stat by game type
    for i, g in pairs(batch) do
        if (not g.sv_on) and ((not g.qa_on) or g_opts.starcraft) then
            stat.reward = (stat.reward or 0) + R[i]:mean()
            stat.success = (stat.success or 0) + success[i]
            stat.count = (stat.count or 0) + 1

            local t = torch.type(batch[i])
            stat['reward_' .. t] = (stat['reward_' .. t] or 0) + R[i]:mean()
            stat['success_' .. t] = (stat['success_' .. t] or 0) + success[i]
            stat['count_' .. t] = (stat['count_' .. t] or 0) + 1
        end
    end
    return stat
end

function apply_curriculum(batch,success)
    for i = 1, #batch do
        if not batch[i].qa_on then
            local gname = batch[i].__typename
            g_factory:collect_result(gname,success[i])
            local count = g_factory:count(gname)
            local total_count = g_factory:total_count(gname)
            local pct = g_factory:success_percent(gname)
            if not g_factory.helpers[gname].frozen then
                if total_count > g_opts.curriculum_total_count then
                    print('freezing ' .. gname)
                    g_factory:hardest(gname)
                    g_factory:freeze(gname)
                else
                    if count > g_opts.curriculum_min_count then
                        if pct > g_opts.curriculum_pct_high then
                            g_factory:harder(gname)
                            print('making ' .. gname .. ' harder')
                            print(format_helpers())
                        end
                        if pct < g_opts.curriculum_pct_low then
                            g_factory:easier(gname)
                            print('making ' .. gname .. ' easier')
                            print(format_helpers())
                        end
                        g_factory:reset_counters(gname)
                    end
                end
            end
        end
    end
end


function train_batch_thread(opts_orig, paramx_orig)
    g_opts = opts_orig
    g_paramx:copy(paramx_orig)
    local stat = train_batch()
    return g_paramdx, stat
end


function format_stat(stat)
    local a = {}
    for n in pairs(stat) do table.insert(a, n) end
    table.sort(a)
    local str = ''
    for i,n in ipairs(a) do
        if string.find(n,'count_') then
            str = str .. n .. ': ' .. string.format("%2.4g",stat[n]) .. ' '
        end
    end
    str = str .. '\n'
    for i,n in ipairs(a) do
        if string.find(n,'reward_') then
            str = str .. n .. ': ' ..  string.format("%2.4g",stat[n]) .. ' '
        end
    end
    str = str .. '\n'
    for i,n in ipairs(a) do
        if string.find(n,'success_') then
            str = str .. n .. ': ' ..  string.format("%2.4g",stat[n]) .. ' '
        end
    end
    str = str .. '\n'
    str = str .. 'bl_cost: ' .. string.format("%2.4g",stat['bl_cost']) .. ' '
    str = str .. 'reward: ' .. string.format("%2.4g",stat['reward']) .. ' '
    str = str .. 'success: ' .. string.format("%2.4g",stat['success']) .. ' '
    str = str .. 'epoch: ' .. stat['epoch']
    return str
end
function print_tensor(a)
    local str = ''
    for s = 1, a:size(1) do str = str .. string.format("%2.4g",a[s]) .. ' '  end
    return str
end
function format_helpers(gname)
    local str = ''
    if not gname then
        for i,j in pairs(g_factory.helpers) do
            str = str .. i .. ' :: '
            str = str .. 'mapW: ' .. print_tensor(j.mapW) .. ' ||| '
            str = str .. 'mapH: ' .. print_tensor(j.mapH) .. ' ||| '
            str = str .. 'wpct: ' .. print_tensor(j.waterpct) .. ' ||| '
            str = str .. 'bpct: ' .. print_tensor(j.blockspct) .. ' ||| '
            str = str .. '\n'
        end
    else
        local j = g_factory.helpers[gname]
        str = str .. gname .. ' :: '
        str = str .. 'mapW: ' .. print_tensor(j.mapW) .. ' ||| '
        str = str .. 'mapH: ' .. print_tensor(j.mapH) .. ' ||| '
        str = str .. 'wpct: ' .. print_tensor(j.waterpct) .. ' ||| '
        str = str .. 'bpct: ' .. print_tensor(j.blockspct) .. ' ||| '
        str = str .. '\n'
    end
    return str
end


function train(N)
    for n = 1, N do
        local stat = {}
        for k = 1, g_opts.nbatches do
            xlua.progress(k, g_opts.nbatches)
            if g_opts.nworker > 1 then
                g_paramdx:zero()
                for w = 1, g_opts.nworker do
                    workers:addjob(w, train_batch_thread,
                        function(paramdx_thread, s)
                            g_paramdx:add(paramdx_thread)
                            for k, v in pairs(s) do
                                stat[k] = (stat[k] or 0) + v
                            end
                        end,
                        g_opts, g_paramx
                    )
                end
                workers:synchronize()
            else
                local s = train_batch()
                for k, v in pairs(s) do
                    stat[k] = (stat[k] or 0) + v
                end
            end
            g_update_param()
        end
        for k, v in pairs(stat) do
            if string.sub(k, 1, 5) == 'count' then
                local s = string.sub(k, 6)
                stat['reward' .. s] = stat['reward' .. s] / v
                stat['success' .. s] = stat['success' .. s] / v
            end
        end
        if stat.bl_count ~= nil and stat.bl_count > 0 then
            stat.bl_cost = stat.bl_cost / stat.bl_count
        else
            stat.bl_cost = 0
        end
        stat.epoch = #g_log + 1
        print(format_stat(stat))
        table.insert(g_log, stat)
        g_save_model()
    end
end