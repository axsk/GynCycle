using GynC
using Memoize
using JLD
using KernelDensity
using Plots

datas = GynC.alldatas()
pyplot(grid=false)

pi0uniformhack = true

densspecies = [8, 31, 44, 50, 76]
densspecies = [31]
denskdebw = 0.1
denscolor = :orangered

patient = 4
sigma = 0.1

trajspecies = 3
trajts = 0:1/4:30
trajclims = (0, 0.04)
trajalphauni = 200
alpha1 = 16
alpha2 = 8
alphalim = 0.01

#const ylimsdens=[(0,0.2), (0,0.2), (0,0.6), (0,1.2), (0,0.1)]
ylimsdens=[(0,0.2)]
ylimstraj=(0,500)

postcolor = :dodgerblue
datacolor = :dodgerblue

kdenpoints = 300

mplegamma = 0.90
inverseweightsstd = 20

isp2 = false # special colors? (something) for plot 2
col = 1

### individual plot functions
# geandert: nsamples, niter
papersave() = (srand(1); paperplot(); savefig("papergync.pdf"))

test() = (srand(1); paperplot(nsamples=50, niter=20, h=1, zmult=5, smoothmult=5))

global lastresult


import GynC: samplepi1, samplepi0

function gendata(nsamples, zmult, smoothmult)
  m    = gyncmodel(samplepi1(nsamples), datas, zmult=zmult, sigma=sigma)
  ms   = GynC.smoothedmodel(m, smoothmult)
  muni = gyncmodel(vcat(samplepi0(nsamples, trajts), m.xs), datas, zmult=0, sigma=sigma)
  m, ms, muni
end

function computeweights(m, ms, muni, niter, mplegamma, h)
  w0 = uniformweights(m.xs)
  ws = Dict{String, Vector{Vector{Float64}}}()

  winv = inverseweights(muni.xs)

  println("computing npmle")
  @time ws["NPMLE"] = GynC.em(m, w0, niter)

  println("computing dsmle")
  @time ws["DS-MLE"] = GynC.em(ms, w0, niter);

  println("computing mple")
  # do half with stepsize h and rest with h/10
  @time begin
    ws["MPLE"]  = GynC.mple(m, w0, round(Int,niter/2), mplegamma, h)
    ws["MPLE"]  = vcat(ws["MPLE"], GynC.mple(m, ws["MPLE"][end], round(Int,niter/2), mplegamma, h/10))
  end

  info("max(delta w)", maximum(abs(ws["MPLE"][end] - ws["MPLE"][end-1])))
  ws["uni"] = [winv]
  ws
end

function paperplot(; nsamples=600, zmult=100, smoothmult=200, niter=5000, h=0.01, kwargs...)
  m, ms, muni = gendata(nsamples, zmult, smoothmult)
  ws = computeweights(m, ms, muni, niter, mplegamma, h)
  p = paperplot(m, muni, ws; kwargs...)
  global lastresult = ((m,ms,muni), ws, p)
  p
end

function plotlast()
  ((m, ms, muni), ws, p) = lastresult
  paperplot(m, muni, ws)
end

function paperplot(m, muni, ws; kwargs...)
  global isp2=true
  pi0plot = plotrow(ws["uni"], muni; kwargs...)

  if pi0uniformhack 
    let ys = pi0plot[1].series_list[1][:y]
      pi0plot[1].series_list[1][:y] = fill(mean(ys), length(ys))
    end
  end

  aplots = vcat(map(x->plotrow(ws[x], m; kwargs...), ["NPMLE", "DS-MLE", "MPLE"])...)

  Plots.plot(pi0plot..., aplots..., size=(1200, 300*3), layout = (4, length(pi0plot)))
end


" return the plots for one row "
function plotrow(ws, m)
  meas = [datas[patient]]


  wpost = bayesposterior(m, meas, ws[end])

  plots = [begin
	     xs = map(x->x[s], m.xs)
	     xlims = (0, GynC.refparms[s] * 5)
	     plotkdeiters(xs, [ws[end]], ylims = ylimsdens[i])
	     plotkde!(xs, wpost, ylims = ylimsdens[i], seriescolor=postcolor, xlims=xlims)
	     end for (i,s) in enumerate(densspecies)]

  plottrajdens(m.xs, ws[end], trajalpha = isp2 ? trajalphauni : alpha1)
  push!(plots, plotdatas!(datas, ylims=ylimstraj, markerstrokecolor=denscolor, color=denscolor, ms=2))

  global isp2 = false

  plottrajdens(m.xs, wpost, trajalpha = alpha2)
  push!(plots, plotdatas!(meas, ylims=ylimstraj, ms=3.5))
  plots
end

### plot helper functions



" plot the kde of iterations of w "
function plotkdeiters(xs, ws; kwargs...)
  colors = (colormap("blues", length(ws)+1)[2:end])'
  p = Plots.plot(legend=false; kwargs...)
  for (w,c) in zip(ws, colors)
    c = denscolor 
    plotkde!(xs, w; seriescolor = c)
  end
  p
end


function plotkde!(xs, w; kwargs...)
  #@show typeof(xs)
  #bw = KernelDensity.default_bandwidth(xs) * denskdebwmult
  #@show bw
  k = kde(xs, weights=w, bandwidth=denskdebw, npoints=kdenpoints)
  plot!(k.x, k.density; kwargs...)
end


@memoize function trajs(xs, trajts=trajts, trajspecies=trajspecies)
  hcat([GynC.forwardsol(x, trajts)[:,GynC.measuredinds[trajspecies]] for x in xs]...)::Array{Float64,2}
end

" plot the kde of the trajectories "
function plottrajdens{T}(xs, weights::Vector{T} = uniformweights(xs);
			 tjs::Array{T,2} = trajs(xs), trajalpha=5, kwargs...)

  as = min.(1., weights*trajalpha)
  i  = as .> alphalim
  Plots.plot(trajts, tjs[:,i], alpha=as[i]', color=:black, legend=false, ylims=ylimstraj)
end

" plot the given data "
function plotdatas!(datas; kwargs...)
  specdatas = map(d->d[:,trajspecies], datas)
  scatter!(0:30, specdatas, color=datacolor, markerstrokecolor=datacolor, legend=false, ms=1.5; kwargs...)
end


### model generation
import GynC.gyncmodel



" compute the bayes posterior for the given model, data and prior "
function bayesposterior(m, data, wprior)
  L = likelihoodmat(m.ys, data, m.measerr)
  GynC.emiteration(wprior, L)
end


### utility function for handling samples, data and weights




" given some sampling, compute the weigts from the inverse of the kde to obtain a weighted sampling corresponding to the uniform distribution" 
function inverseweights(xs::Vector)
  w=1./mykde(xs,xs,inverseweightsstd)
  normalize!(w, 1)
end

uniformweights(xs::Vector) = uniformweights(length(xs))
uniformweights(n::Int)     = fill(1/n, n)


" compute the kde evaluations at 'evals', given the points 'data'.
 for high dimensions adjust stdmult to tweak the covariance "
function mykde(data, evals, stdmult)
  dim = length(data[1])
  stds = [KernelDensity.default_bandwidth(map(x->x[d], data)) for d in 1:dim] * stdmult
  @show stds[densspecies]
  map(evals) do e
    pdf(MvNormal(e, stds), hcat(data...)) |> sum
  end
end
