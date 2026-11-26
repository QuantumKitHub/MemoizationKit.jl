module MemoizationKitEnzymeExt

using MemoizationKit, Enzyme

@inline EnzymeRules.inactive_type(::Type{<:MemoizationKit.AbstractCache}) = true

end
