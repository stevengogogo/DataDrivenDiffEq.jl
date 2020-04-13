# TODO I think here is some potential for faster computation
# However, up to 25 states, the algorithm works fine and fast (main knobs are rtol and maxiter)
# This is the specialized version assuming a mass matrix form / linear in dx
# M(x, p)*dx = f(x, p)
# Where M is diagonal!

# TODO preallocation
function ISInDy(X::AbstractArray, Ẋ::AbstractArray, Ψ::Basis; maxiter::Int64 = 10, rtol::Float64 = 0.99, p::AbstractArray = [], opt::T = ADM()) where T <: DataDrivenDiffEq.Optimise.AbstractSubspaceOptimiser
    @assert size(X)[end] == size(Ẋ)[end]
    nb = length(Ψ.basis)

    # Compute the library and the corresponding nullspace
    θ = Ψ(X, p = p)
    # Init for sweep over the differential variables
    eqs = Operation[]
    ps = Operation[]
    Ξ = zeros(eltype(θ), length(Ψ)*2, size(Ẋ, 1))

    @inbounds for i in 1:size(Ẋ, 1)
        dθ = hcat(map((dxi, ti)->dxi.*ti, Ẋ[i, :], eachcol(θ))...)
        Θ = vcat(dθ, θ)
        N = nullspace(Θ', rtol = rtol)
        Q = deepcopy(N) # Deepcopy for inplace

        # Find sparse vectors in nullspace
        # Calls effectively the ADM algorithm with varying initial conditions
        DataDrivenDiffEq.fit!(Q, N', opt, maxiter = maxiter)


        # Compute pareto front
        pareto = map(q->norm([norm(q, 0) ;norm(Θ'*q, 2)], 2), eachcol(Q))
        score, posmin = findmin(pareto)
        # Get the corresponding eqs
        q_best = Q[:, posmin]
        # Remove small entries
        q_best[abs.(q_best) .< opt.λ] .= zero(eltype(q_best))
        rmul!(q_best ,one(eltype(q_best))/maximum(abs.(q_best)))

        # Numerator and Denominator
        # Maybe there is a better way of doing this
        #Fn, pn = derive_parameterized_eqs(q_best[nb+1:end], Ψ)
        #Fd, pd = derive_parameterized_eqs(q_best[1:nb], Ψ)
        Ξ[:, i] .= q_best[:]
        #push!(eqs, -Fn/Fd)
        #push!(ps, [pn; pd])
    end


    return ImplicitSparseIdentificationResult(Ξ, Ψ, maxiter, opt, true, Ẋ, X, p = p)
end


function ImplicitSparseIdentificationResult(coeff::AbstractArray, equations::Basis, iters::Int64, opt::T, convergence::Bool, Y::AbstractVecOrMat, X::AbstractVecOrMat; p::AbstractArray = []) where T <: Union{Optimise.AbstractOptimiser, Optimise.AbstractSubspaceOptimiser}

    sparsities = zeros(Int64, 2, size(coeff, 2))
    sparsities[1, :] .= Int64.(norm(eachcol(coeff[1:length(equations), :]), 0))
    sparsities[2, :] .= Int64.(norm(eachcol(coeff[length(equations)+1:end, :]), 0))

    b_, p_ = derive_implicit_parameterized_eqs(coeff, equations, sum.(eachrow(sparsities)))
    ps = [p; p_]

    Ŷ = b_(X, p = ps)
    training_error = norm.(eachrow(Y-Ŷ), 2)
    aicc = similar(training_error)

    for i in 1:length(aicc)
        aicc[i] = AICC(sum(sparsities[:, i]), view(Ŷ, i, :) , view(Y, i, :))
    end
    return SparseIdentificationResult(coeff, [p...;p_...], b_ , opt, iters, convergence,  training_error, aicc,  sum.(eachcol(sparsities)))
end



function derive_implicit_parameterized_eqs(Ξ::AbstractArray{T, 2}, b::Basis, sparsities::Array{Int64, 1}) where T <: Real
    @parameters p[1:sum(sparsities)]
    p_ = zeros(eltype(Ξ), sum(sparsities))
    cnt = 1
    b_ = Basis(Operation[], variables(b), parameters = [parameters(b)...; p...])

    for i=1:size(Ξ, 2)
        eq_d = nothing
        eq_n = nothing
        # Denominator
        for j = 1:length(b)
            if !iszero(Ξ[j,i])
                if eq_d === nothing
                    eq_d = p[cnt]*b[j]
                else
                    eq_d += p[cnt]*b[j]
                end
                p_[cnt] = Ξ[j,i]
                cnt += 1
            end
        end
        # Numerator
        for j = 1:length(b)
            if !iszero(Ξ[j+length(b),i])
                if eq_n === nothing
                    eq_n = p[cnt]*b[j]
                else
                    eq_n += p[cnt]*b[j]
                end
                p_[cnt] = Ξ[j+length(b),i]
                cnt += 1
            end
        end

        push!(b_, -eq_n ./ eq_d)
    end
    b_, p_
end
