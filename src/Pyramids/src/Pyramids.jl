module Pyramids

using LinearAlgebra, FFTW, Images, Interpolations, Colors
using DSP # I need this only for conv2

export ImagePyramid, PyramidType, ComplexSteerablePyramid, LaplacianPyramid, GaussianPyramid
export subband, toimage, update_subband, update_subband!, test

"abstract supertype for the variety of pyramids that can be constructed."
abstract type PyramidType end
abstract type SimplePyramid <: PyramidType end

"""Type that indicates a complex steerable pyramid. [1]

[1] http://www.cns.nyu.edu/~eero/steerpyr/"""
struct ComplexSteerablePyramid <: PyramidType
end

"""Type that indicates a Laplacian pyramid. [1]

[1] persci.mit.edu/pub_pdfs/pyramid83.pdf"""
struct LaplacianPyramid <: SimplePyramid
end

"""Type that indicates a Gaussian pyramid. [1]

[1] http://persci.mit.edu/pub_pdfs/RCA84.pdf"""
struct GaussianPyramid <: SimplePyramid
end

"""Type that represents a concrete pyramidal representation of a given input image. Each type of pyramid has its own parameters. The basic construction method is, for example

```pyramid = ImagePyramid(im, ComplexSteerablePyramid(), scale=0.5^0.25)```

See the code for more information on optional arguments."""
struct ImagePyramid
    scale::Real
    num_levels::Int
    num_orientations::Int
    t::PyramidType
    pyramid_bands::Dict

    function ImagePyramid(pyr::ImagePyramid)
        return deepcopy(pyr)
    end

    function ImagePyramid(im::Array, t::ComplexSteerablePyramid; scale=0.5, min_size=15, num_orientations=8, max_levels=23, twidth=1)

        t = ComplexSteerablePyramid()
        scale = scale
        num_orientations = num_orientations

        im_dims = size(im)
        h = im_dims[1]
        w = im_dims[2]

        num_levels = min(ceil.(log2(minimum([h w]))/log2(1/scale) - (log2(min_size)/log2(1/scale))),max_levels);

        pyramid_bands, mtx, harmonics = build_complex_steerable_pyramid(im,
            num_levels, num_levels, order=num_orientations-1,
            twidth=twidth, scale=scale)

        return new(scale,num_levels,num_orientations,t,pyramid_bands)
    end

    function ImagePyramid(im::Array, t::GaussianPyramid; min_size=15, max_levels=23, filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])
        this = new()

        pyramid_bands, num_levels = generate_gaussian_pyramid(im,
                min_size=min_size, max_levels=max_levels, filter=filter)

        scale = 0.5
        pyramid_bands = pyramid_bands
        num_orientations = 1
        num_levels = num_levels

        return new(scale,num_levels,num_orientations,t,pyramid_bands)
    end

    function ImagePyramid(im::Array, t::LaplacianPyramid; min_size=15, max_levels=23, filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])

        pyramid_bands, num_levels = generate_laplacian_pyramid(im,
                min_size=min_size, max_levels=max_levels, filter=filter)

        scale = 0.5
        pyramid_bands = pyramid_bands
        num_orientations = 1
        num_levels = num_levels

        return new(scale,num_levels,num_orientations,t,pyramid_bands)
    end
    # I am not sure this is needed
    # function ImagePyramid(pyramid_bands::Dict, scale, t, num_levels, num_orientations)
    #     return new(scale,num_levels,num_orientations,t,pyramid_bands)
    # end
end

##############################
# Functions

"""
    subband(pyramid::ImagePyramid, level; orientation=())

Returns the sub-band of the `pyramid` at `level` and at `orientation.` If orientation is not provided, `subband` assumes that the pyramid is not oriented.

Level 0 is always the high frequency residual."""
function subband(pyramid::ImagePyramid, level; orientation = ())
    if isempty(orientation)
        return pyramid.pyramid_bands[level]
    else
        return pyramid.pyramid_bands[level][orientation]
    end
end

function update_subband!(pyramid::ImagePyramid, level, new_subband; orientation = ())
    if isempty(orientation)
        pyramid.pyramid_bands[level] = copy(new_subband)
    else
        pyramid.pyramid_bands[level][orientation] = copy(new_subband)
    end

    return pyramid
end

function update_subband(pyramid::ImagePyramid, level, new_subband; orientation = ())
    newpyramid = ImagePyramid(pyramid)
    return update_subband!(newpyramid, level, new_subband, orientation=orientation)
end

"Converts a pyramid to a 2-D array (not of type `Image`!)"
function toimage(pyramid::ImagePyramid)
    if typeof(pyramid.t) <: ComplexSteerablePyramid
        im = reconstruct_complex_steerable_pyramid(pyramid, scale=pyramid.scale)
    elseif typeof(pyramid.t) <: LaplacianPyramid
        im = reconstruct_laplacian_pyramid(pyramid)
    elseif typeof(pyramid.t) <: GaussianPyramid
        im = subband(pyramid, 0)
    else
        error("Unsupported pyramid type $(typeof(pyramid.T))")
    end

    return im
end

##############################
# Private functions for building Gaussian and Laplacian pyramids.

function convolve_reflect(im, filter)
    filter_len = length(filter)
    filter_offset::Int = (filter_len-1)/2

    padded_im = zeros((size(im,1) + filter_len*2), (size(im,1) + filter_len*2))

    padded_im[(filter_len+1):(end-filter_len), (filter_len+1):(end-filter_len)] = im

    padded_im[(filter_len+1):(end-filter_len), 1:filter_len] =
        reverse(padded_im[(filter_len+1):(end-filter_len),
                (filter_len+2):(2*filter_len+1)], dims=2)
    padded_im[(filter_len+1):(end-filter_len), (end-filter_len+1):end] =
            reverse(padded_im[(filter_len+1):(end-filter_len),
                (end-2*filter_len):(end-filter_len-1)], dims=2)
    padded_im[1:filter_len, (filter_len+1):(end-filter_len),] =
        reverse(padded_im[(filter_len+2):(1+2*filter_len),
                (filter_len+1):(end-filter_len)], dims=1)
    padded_im[(end-filter_len+1):end, (filter_len+1):(end-filter_len)] =
            reverse(padded_im[(end-2*filter_len):(end-filter_len-1),
                (filter_len+1):(end-filter_len)], dims=1)

    new_im = DSP.conv(filter, filter, padded_im)

    new_im = new_im[(1+filter_len+filter_offset):(end-filter_len-filter_offset), (1+filter_len+filter_offset):(end-filter_len-filter_offset)]
    return new_im
end

function reduce(im; filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])
    new_im = convolve_reflect(im, filter)
    return new_im[1:2:end, 1:2:end]
end

function expand(im; filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])
    new_im = zeros((size(im, 1)*2, size(im, 2)*2))
    new_im[1:2:end, 1:2:end] = im

    new_im = convolve_reflect(new_im, filter)
    return new_im
end

function generate_gaussian_pyramid(im; min_size=15, max_levels=23, filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])
    im = convert(Array{Float64}, copy(im))

    pyramid_bands = Dict{Integer, Array}()

    im_dims = collect(size(im))
    num_levels = min(max_levels, ceil.(Int, log2(minimum(im_dims)) - log2(min_size)))

    for i = 1:num_levels
        pyramid_bands[i-1] = im
        im = reduce(im, filter=filter)
    end

    return (pyramid_bands, num_levels)
end

function generate_laplacian_pyramid(im; min_size=15, max_levels=23, filter=[0.0625; 0.25; 0.375; 0.25; 0.0625])
    im = convert(Array{Float64}, copy(im))

    pyramid_bands = Dict{Integer, Array}()

    im_dims = collect(size(im))

    num_levels = min(max_levels, ceil.(Int, log2(minimum(im_dims)) - log2(min_size)))

    filter_offset::Int = (length(filter)-1)/2

    for i = 1:num_levels
        reduced_im = reduce(im, filter=filter)
        next_im = expand(reduced_im)
        diff_im = im - next_im

        pyramid_bands[i-1] = diff_im

        im = reduced_im
    end

    pyramid_bands[num_levels] = im

    return (pyramid_bands, num_levels)
end

function reconstruct_laplacian_pyramid(pyramid::ImagePyramid)
    output_im::Array{Float64} = subband(pyramid, pyramid.num_levels)

    for i = (pyramid.num_levels-1):-1:0
        output_im = expand(output_im)
        output_im += subband(pyramid, i)
    end

    return output_im
end

##############################
# Private functions for building complex steerable pyramids.

function construct_steering_matrix(harmonics, angles; even = true)
    numh = 2*length(harmonics) - any(harmonics .== 0)

    imtx = zeros(length(angles), numh)
    col = 1
    for h in harmonics
        args = h * angles

        if h == 0
            imtx[:,col] = ones(angles)
            col += 1
        elseif !even
            imtx[:,col] = sin.(args)
            imtx[:,col+1] = -cos.(args)
            col += 2
        else
            imtx[:,col] = cos.(args)
            imtx[:,col+1] = sin.(args)
            col += 2
        end
    end

    r = rank(imtx)

    if (r != numh) && (r != length(angles))
        warning("Matrix is not full rank")
    end

    return pinv(imtx)
end

function raisedcosine(width=1, position=0, values=[0,1])
    sz = 256 # arbitrary
    X = collect( pi * (-sz-1:1) / (2 * sz) )
    Y = @. values[1] + ( (values[2]-values[1]) * cos(X)^2 )

    Y[1] = Y[2]
    Y[sz+3] = Y[sz+2]
    X = @.  position + (2*width/pi) * (X + pi/4)

    return (X, Y)
end

function build_complex_steerable_pyramid(im,
            height, nScales; order=3, twidth=1, scale=0.5)
    pyramid_bands = Dict{Integer, Union{Array, Dict{Integer, Array}}}()
    num_orientations = order + 1
    # generate steering matrix and harmonics info
    if mod.(num_orientations, 2) == 0
        # on 0.6 it was   ((0:((num_orientations/2)-1))*2+1)'
        harmonics = (1:2:(num_orientations/2-1)*2+1)
    else
        #on 0.6 it was ((0:((num_orientations-1)/2))*2)'
        harmonics = 0:2:(num_orientations-1)
    end

    steeringmatrix = construct_steering_matrix(harmonics,
                pi*(0:(num_orientations-1))/num_orientations, even=true)

    imdft = fftshift(fft(im))
    im_dims = size(im)
    ctr = ceil.(Int, (im_dims .+ 0.5) ./ 2. )

    angle = broadcast(atan,
            (((1:im_dims[1]) .- ctr[1]) ./ (im_dims[1]/2)),
            (((1:im_dims[2]) .- ctr[2]) ./ (im_dims[2]/2))') #SLOOW
    log_rad = broadcast((x,y) -> log2(sqrt(x^2 + y^2)),
            (((1:im_dims[1]) .- ctr[1]) ./ (im_dims[1]/2)),
            (((1:im_dims[2]) .- ctr[2]) ./ (im_dims[2]/2))') #SLOOW
    log_rad[ctr[1], ctr[2]] = log_rad[ctr[1], ctr[2]-1]

    Xrcos, Yrcos = raisedcosine(twidth, (-twidth/2), [0 1])
    Yrcos = sqrt.(Yrcos)
    YIrcos = @. sqrt(1 - Yrcos^2)

    # generate high frequency residual
    Yrcosinterpolant = interpolate((Xrcos,), Yrcos, Gridded(Linear()) )
    Yrcosinterpolant_ext = extrapolate(Yrcosinterpolant,Flat())
    hi0mask = map(Yrcosinterpolant_ext,log_rad)
    hi0dft =  imdft .* hi0mask;

    pyramid_bands[0] = ifft(ifftshift(hi0dft));

    YIrcosinterpolant = interpolate((Xrcos,), YIrcos, Gridded(Linear()))
    YIrcosinterpolant_ext = extrapolate(YIrcosinterpolant,Flat())
    lo0mask = map(YIrcosinterpolant_ext,log_rad)
    lo0dft = imdft .* lo0mask

    for ht = height:-1:1
        Xrcos = Xrcos .- log2(1/scale)
        order = num_orientations - 1

        cnst = (2^(2*order))*(factorial(order)^2)/(num_orientations*factorial(2*order))

        Yrcosinterpolant = interpolate((Xrcos,), Yrcos, Gridded(Linear()))
        Yrcosinterpolant_ext = extrapolate(Yrcosinterpolant,Flat())
        himask = map(Yrcosinterpolant_ext,log_rad)

        # loop through each orientation band
        pyramid_level = Dict{Integer, Array}()

        for b in 1:num_orientations

            banddft = map(zip(lo0dft,himask,angle) ) do (lo0dft_i,himask_i,angle_i)
                ang = angle_i-pi*(b-1)/num_orientations
                a = (abs(mod(pi+ang, 2*pi) - pi) < pi/2) *
                            (2*sqrt(cnst) * (cos(ang)^order))
                (complex(0,-1)^(num_orientations-1) *
                             lo0dft_i * himask_i) * a
            end
            pyramid_level[b] = ifft(ifftshift(banddft))
        end

        pyramid_bands[height-ht+1] = pyramid_level

        dims = size(lo0dft)
        ctr = ceil.(Int, (dims .+ 0.5)./2)

        lodims = round.(Int, im_dims[1:2].* (scale^(nScales-ht+1)) )

        loctr = ceil.(Int, (lodims.+0.5)./2)
        lostart = @. ctr - loctr+1
        loend = @. lostart + lodims - 1

        log_rad = log_rad[lostart[1]:loend[1], lostart[2]:loend[2]]
        angle = angle[lostart[1]:loend[1], lostart[2]:loend[2]]
        lodft = lo0dft[lostart[1]:loend[1], lostart[2]:loend[2]]
        YIrcos = @. abs(sqrt(1 - Yrcos^2))

        YIrcosinterpolant = interpolate((Xrcos,), YIrcos, Gridded(Linear()))
        YIrcosinterpolant_ext = extrapolate(YIrcosinterpolant,Flat())
        lomask = map(YIrcosinterpolant_ext,log_rad)

        lo0dft = lomask .* lodft
    end

    pyramid_bands[height+1] = real(ifft(ifftshift(lo0dft)))

    return (pyramid_bands, steeringmatrix, harmonics)
end

function make_angle_grid(sz, phase=0, origin=-1)
    if length(sz) == 1
        sz = [sz, sz]
    end

    if origin == -1
        origin = (sz + 1)/2
    end

    xramp = ones(round(Int, sz[1]), 1) * collect((1:sz[2]) .- origin[2])'
    yramp = collect((1:sz[1]) .- origin[1]) * ones(1, round.(Int, sz[2]))

    res = atan.(yramp, xramp)

    res = mod.(res .+ (pi-phase), 2*pi) .- pi

    return res
end

function reconstruct_steerable_pyramid(pyr::ImagePyramid;
        levs="all", bands="all", twidth=1, scale=0.5)
    dims = collect(size(subband(pyr, 0)))
    im_dft = zeros(Complex{Float64}, size(subband(pyr, 0)))

    ctr = ceil.(Int, (dims .+ 0.5) ./ 2)

    angle = broadcast(atan,
            (((1:dims[1]) .- ctr[1]) ./ (dims[1]/2)),
            (((1:dims[2]) .- ctr[2]) ./ (dims[2]/2))') #SLOOW
    log_rad = broadcast((x,y) -> log2(sqrt.(x.^2 + y.^2)),
        (((1:dims[1]) .- ctr[1]) ./ (dims[1]/2)),
        (((1:dims[2]) .- ctr[2]) ./ (dims[2]/2))') #SLOOW
    log_rad[ctr[1], ctr[2]] = log_rad[ctr[1], ctr[2]-1]
    log_rad0 = log_rad
    angle0 = angle

    Xrcos, Yrcos = raisedcosine(twidth, (-twidth/2), [0 1])
    Yrcos = sqrt.(Yrcos)
    YIrcos = @. sqrt(1 - Yrcos^2)

    # Start with low frequency residual
    low_dft = fftshift(fft(subband(pyr, pyr.num_levels+1)))

    lodims = collect(size(low_dft))
    loctr = ceil.(Int, (lodims .+ 0.5)./2)
    lostart = @. ctr - loctr + 1
    loend = @. lostart + lodims - 1

    log_rad = log_rad0[lostart[1]:loend[1], lostart[2]:loend[2]]
    angle = angle0[lostart[1]:loend[1], lostart[2]:loend[2]]

    Xrcos = Xrcos .- (log2(1/scale)*pyr.num_levels)
    YIrcosinterpolant = interpolate((Xrcos,), YIrcos, Gridded(Linear()))
    YIrcosinterpolant_ext = extrapolate(YIrcosinterpolant,Flat())
    lomask = map(YIrcosinterpolant_ext,log_rad)

    im_dft[lostart[1]:loend[1], lostart[2]:loend[2]] += low_dft .* lomask

    # Accumulate mid-bamds
    for level = pyr.num_levels:-1:1
        lodims = collect(size(subband(pyr, level, orientation=1)))
        loctr = ceil.(Int, (lodims .+ 0.5) ./ 2)
        lostart = @. ctr - loctr+1
        loend = @. lostart + lodims - 1

        log_rad = copy(log_rad0[lostart[1]:loend[1], lostart[2]:loend[2]])
        angle = copy(angle0[lostart[1]:loend[1], lostart[2]:loend[2]])

        Yrcosinterpolant = interpolate((Xrcos,), Yrcos, Gridded(Linear()))
        Yrcosinterpolant_ext = extrapolate(Yrcosinterpolant,Flat())
        himask = map(Yrcosinterpolant_ext,log_rad)

        Xrcos = Xrcos .+ log2(1/scale)
        order = pyr.num_orientations - 1

        cnst = ((complex(0,1))^(pyr.num_orientations-1)) *
            sqrt((2^(2*order))*(factorial(order)^2)/
                    (pyr.num_orientations*factorial(2*order)))

        for orientation = 1:pyr.num_orientations
            band_dft = fftshift(fft(subband(pyr, level, orientation=orientation)))
            ang = angle .- (pi*(orientation-1)/pyr.num_orientations)
            angle_mask = 2 .* (abs.(mod.(pi .+ ang, 2*pi) .- pi) .< pi/2) .*
                (cnst .* (cos.(ang).^order))

            im_dft[lostart[1]:loend[1], lostart[2]:loend[2]] += band_dft .*
             himask .* angle_mask
        end

        YIrcosinterpolant = interpolate((Xrcos,), YIrcos, Gridded(Linear()))
        YIrcosinterpolant_ext = extrapolate(YIrcosinterpolant,Flat())
        lomask = map(YIrcosinterpolant_ext,log_rad)

        # Everything must be scaled by the low-frequency mask
        im_dft[lostart[1]:loend[1], lostart[2]:loend[2]] .*= lomask
    end

    # Add high frequency residual
    Yrcosinterpolant = interpolate((Xrcos,), Yrcos, Gridded(Linear()) )
    Yrcosinterpolant_ext = extrapolate(Yrcosinterpolant,Flat())
    hi0mask = map(Yrcosinterpolant_ext,log_rad)
    im_dft += fftshift(fft(subband(pyr, 0))) .* hi0mask;

    return real(ifft(ifftshift(im_dft)))
end

# make the complex steerable pyramid real
function convert_complex_steerable_pyramid_to_real(pyramid::ImagePyramid;
            levs="all", bands="all", twidth=1, scale=0.5)
    pyramid = ImagePyramid(pyramid)
    num_levels = pyramid.num_levels
    num_orientations = pyramid.num_orientations

    for nsc in 1:num_levels
        dims = collect(size(subband(pyramid, nsc, orientation=1)))
        ctr = ceil.(Int, (dims .+ 0.5)./ 2)
        ang = make_angle_grid(dims, 0, ctr)
        ang[ctr[1], ctr[2]] = -pi/2

        for nor = 1:num_orientations
            ch = subband(pyramid, nsc, orientation=nor)

            ang0 = pi*(nor-1)/num_orientations
            xang = mod.(ang .- (ang0+pi), 2*pi) .- pi

            # this creates an angular mask
            amask = 2.0 .* (abs.(xang) .< pi/2) .+ (abs.(xang) .== pi/2)
            amask[ctr[1], ctr[2]] = 1.0
            amask[:,1] .= 1.0
            amask[1,:] .= 1.0

            # and masks the fft by it
            amask = fftshift(amask)
            ch = ifft(amask.*fft(ch))
            ch = 0.5 .* real(ch)

            # then creates a new pyramid
            update_subband!(pyramid, nsc, ch, orientation=nor)
        end
    end

    # and returns it as a real
    return pyramid
end

function reconstruct_complex_steerable_pyramid(pyramid::ImagePyramid;
            levs="all", bands="all", twidth=1, scale=0.5)
    real_pyramid = convert_complex_steerable_pyramid_to_real(pyramid,
        levs=levs, bands=bands, twidth=twidth, scale=scale)
    return reconstruct_steerable_pyramid(real_pyramid, levs=levs,
        bands=bands, twidth=twidth, scale=scale)
end

end
