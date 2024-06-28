-{stat:
    -- Declaring the [ternary] metafunction. As a
    -- metafunction, it only exists within -{...},
    -- i.e. not in the program itself.
    function ternary (cond, b1, b2)
        return +{ 
            (function()
                if -{cond} then
                    return -{b1}
                else
                    return -{b2}
                end
            end)() 
        }
    end
}
local lang = "en"
hi = -{ ternary (+{lang=="fr"}, +{"Bonjour"}, +{"Hello"}) }
print (hi)
lang = "fr"
hi = -{ ternary (+{lang=="fr"}, +{"Bonjour"}, +{"Hello"}) }
print (hi)
