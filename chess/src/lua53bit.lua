--local bit = require('bit')

--return bit

return {
    band=function(a,b) return a & b end,
    bor=function(a,b) return a | b end,
    bxor=function(a,b) return a ~ b end,
    rshift=function(a,b) return a >> b end,
    lshift=function(a,b) return a << b end,
}