/*
 * UpdaterGPUScBFM_AB_Type.cpp
 *
 *  Created on: 27.07.2017
 *      Author: Ron Dockhorn
 */

#include "UpdaterGPUScBFM_AB_Type.h"
#include "graphColoring.tpp"

#include <algorithm>                        // fill, sort
#include <chrono>                           // std::chrono::high_resolution_clock
#include <cstdio>                           // printf
#include <cstdlib>                          // exit
#include <cstring>                          // memset
#include <ctime>
#include <iostream>
#include <stdexcept>
#include <stdint.h>
#include <sstream>

#include "cudacommon.hpp"
#include "SelectiveLogger.hpp"

#define DEBUG_UPDATERGPUSCBFM_AB_TYPE 100



/* 512=8^3 for a range of bonds per direction of [-4,3] */
__device__ __constant__ bool dpForbiddenBonds[512]; //false-allowed; true-forbidden

/**
 * These will be initialized to:
 *   DXTable_d = { -1,1,0,0,0,0 }
 *   DYTable_d = { 0,0,-1,1,0,0 }
 *   DZTable_d = { 0,0,0,0,-1,1 }
 * I.e. a table of three random directional 3D vectors \vec{dr} = (dx,dy,dz)
 */
__device__ __constant__ intCUDA DXTable_d[6]; //0:-x; 1:+x; 2:-y; 3:+y; 4:-z; 5+z
__device__ __constant__ intCUDA DYTable_d[6]; //0:-x; 1:+x; 2:-y; 3:+y; 4:-z; 5+z
__device__ __constant__ intCUDA DZTable_d[6]; //0:-x; 1:+x; 2:-y; 3:+y; 4:-z; 5+z

/* will this really bring performance improvement? At least constant cache
 * might be as fast as register access when all threads in a warp access the
 * the same constant */
__device__ __constant__ uint32_t dcBoxXM1   ;  // mLattice size in X-1
__device__ __constant__ uint32_t dcBoxYM1   ;  // mLattice size in Y-1
__device__ __constant__ uint32_t dcBoxZM1   ;  // mLattice size in Z-1
__device__ __constant__ uint32_t dcBoxXLog2 ;  // mLattice shift in X
__device__ __constant__ uint32_t dcBoxXYLog2;  // mLattice shift in X*Y

template< typename T > struct intCUDAVec;
template<> struct intCUDAVec< int16_t >{ typedef short4 value_type; };
template<> struct intCUDAVec< int32_t >{ typedef int4   value_type; };



/* Since CUDA 5.5 (~2014) there do exist texture objects which are much
 * easier and can actually be used as kernel arguments!
 * @see https://devblogs.nvidia.com/parallelforall/cuda-pro-tip-kepler-texture-objects-improve-performance-and-flexibility/
 * "What is not commonly known is that each outstanding texture reference that
 *  is bound when a kernel is launched incurs added launch latency—up to 0.5 μs
 *  per texture reference. This launch overhead persists even if the outstanding
 *  bound textures are not even referenced by the kernel. Again, using texture
 *  objects instead of texture references completely removes this overhead."
 * => they only exist for kepler -.- ...
 */

__device__ uint32_t hash( uint32_t a )
{
    /* https://web.archive.org/web/20120626084524/http://www.concentric.net:80/~ttwang/tech/inthash.htm
     * Note that before this 2007-03 version there were no magic numbers.
     * This hash function doesn't seem to be published.
     * He writes himself that this shouldn't really be used for PRNGs ???
     * @todo E.g. check random distribution of randomly drawn directions are
     *       they rouhgly even?
     * The 'hash' or at least an older version of it can even be inverted !!!
     * http://c42f.github.io/2015/09/21/inverting-32-bit-wang-hash.html
     * Somehow this also gets attibuted to Robert Jenkins?
     * https://gist.github.com/badboy/6267743
     * -> http://www.burtleburtle.net/bob/hash/doobs.html
     *    http://burtleburtle.net/bob/hash/integer.html
     */
    a = ( a + 0x7ed55d16 ) + ( a << 12 );
    a = ( a ^ 0xc761c23c ) ^ ( a >> 19 );
    a = ( a + 0x165667b1 ) + ( a << 5  );
    a = ( a + 0xd3a2646c ) ^ ( a << 9  );
    a = ( a + 0xfd7046c5 ) + ( a << 3  );
    a = ( a ^ 0xb55a4f09 ) ^ ( a >> 16 );
    return a;
}

template< typename T >
__device__ __host__ bool isPowerOfTwo( T const & x )
{
    return ! ( x == 0 ) && ! ( x & ( x - 1 ) );
}

uint32_t UpdaterGPUScBFM_AB_Type::linearizeBoxVectorIndex
(
    uint32_t const & ix,
    uint32_t const & iy,
    uint32_t const & iz
)
{
    #ifdef NOMAGIC
        return ( ix % mBoxX ) +
               ( iy % mBoxY ) * mBoxX +
               ( iz % mBoxZ ) * mBoxX * mBoxY;
    #else
        assert( isPowerOfTwo( mBoxXM1 + 1 ) );
        assert( isPowerOfTwo( mBoxYM1 + 1 ) );
        assert( isPowerOfTwo( mBoxZM1 + 1 ) );
        return   ( ix & mBoxXM1 ) +
               ( ( iy & mBoxYM1 ) << mBoxXLog2  ) +
               ( ( iz & mBoxZM1 ) << mBoxXYLog2 );
    #endif
}

__device__ inline uint32_t linearizeBoxVectorIndex
(
    uint32_t const & ix,
    uint32_t const & iy,
    uint32_t const & iz
)
{
    #if DEBUG_UPDATERGPUSCBFM_AB_TYPE > 10
        assert( isPowerOfTwo( dcBoxXM1 + 1 ) );
        assert( isPowerOfTwo( dcBoxYM1 + 1 ) );
        assert( isPowerOfTwo( dcBoxZM1 + 1 ) );
    #endif
    return   ( ix & dcBoxXM1 ) +
           ( ( iy & dcBoxYM1 ) << dcBoxXLog2  ) +
           ( ( iz & dcBoxZM1 ) << dcBoxXYLog2 );
}

/**
 * Checks the 3x3 grid one in front of the new position in the direction of the
 * move given by axis.
 *
 * @verbatim
 *           ____________
 *         .'  .'  .'  .'|
 *        +---+---+---+  +     y
 *        | 6 | 7 | 8 |.'|     ^ z
 *        +---+---+---+  +     |/
 *        | 3/| 4/| 5 |.'|     +--> x
 *        +-/-+-/-+---+  +
 *   0 -> |+---+1/| 2 |.'  ^          ^
 *        /|/-/|/-+---+   /          / axis direction +z (axis = 0b101)
 *       / +-/-+         /  2 (*dz) /                              ++|
 *      +---+ /         /                                         /  +/-
 *      |/X |/         L                                        xyz
 *      +---+  <- X ... current position of the monomer
 * @endverbatim
 *
 * @param[in] axis +-x, +-y, +-z in that order from 0 to 5, or put in another
 *                 equivalent way: the lowest bit specifies +(1) or -(0) and the
 *                 Bit 2 and 1 specify the axis: 0b00=x, 0b01=y, 0b10=z
 * @return Returns true if any of that is occupied, i.e. if there
 *         would be a problem with the excluded volume condition.
 */
__device__ inline bool checkFront
(
    cudaTextureObject_t const & texLattice,
    intCUDA             const & x0        ,
    intCUDA             const & y0        ,
    intCUDA             const & z0        ,
    intCUDA             const & axis
)
{
    bool isOccupied = false;
#if 0
    #define TMP_FETCH( x,y,z ) \
        tex1Dfetch< uint8_t >( texLattice, linearizeBoxVectorIndex(x,y,z) )
    intCUDA const shift  = 4*(axis & 1)-2;
    intCUDA const iMove = axis >> 1;
    /* reduce branching by parameterizing the access axis, but that
     * makes the memory accesses more random again ???
     * for i0=0, i1=1, axis=z (same as in function doxygen ascii art)
     *    4 3 2
     *    5 0 1
     *    6 7 8
     */
    intCUDA r[3] = { x0, y0, z0 };
    r[ iMove ] += shift; isOccupied = TMP_FETCH( r[0], r[1], r[2] ); /* 0 */
    intCUDA i0 = iMove+1 >= 3 ? iMove+1-3 : iMove+1;
    intCUDA i1 = iMove+2 >= 3 ? iMove+2-3 : iMove+2;
    r[ i0 ]++; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 1 */
    r[ i1 ]++; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 2 */
    r[ i0 ]--; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 3 */
    r[ i0 ]--; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 4 */
    r[ i1 ]--; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 5 */
    r[ i1 ]--; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 6 */
    r[ i0 ]++; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 7 */
    r[ i0 ]++; isOccupied |= TMP_FETCH( r[0], r[1], r[2] ); /* 8 */
    #undef TMP_FETCH
#elif 0 // defined( NOMAGIC )
    intCUDA const shift = 4*(axis & 1)-2;
    switch ( axis >> 1 )
    {
        #define TMP_FETCH( x,y,z ) \
            tex1Dfetch< uint8_t >( texLattice, linearizeBoxVectorIndex(x,y,z) )
        case 0: //-+x
        {
            uint32_t const x1 = x0 + shift;
            isOccupied = TMP_FETCH( x1, y0 - 1, z0     ) |
                         TMP_FETCH( x1, y0    , z0     ) |
                         TMP_FETCH( x1, y0 + 1, z0     ) |
                         TMP_FETCH( x1, y0 - 1, z0 - 1 ) |
                         TMP_FETCH( x1, y0    , z0 - 1 ) |
                         TMP_FETCH( x1, y0 + 1, z0 - 1 ) |
                         TMP_FETCH( x1, y0 - 1, z0 + 1 ) |
                         TMP_FETCH( x1, y0    , z0 + 1 ) |
                         TMP_FETCH( x1, y0 + 1, z0 + 1 );
            break;
        }
        case 1: //-+y
        {
            uint32_t const y1 = y0 + shift;
            isOccupied = TMP_FETCH( x0 - 1, y1, z0 - 1 ) |
                         TMP_FETCH( x0    , y1, z0 - 1 ) |
                         TMP_FETCH( x0 + 1, y1, z0 - 1 ) |
                         TMP_FETCH( x0 - 1, y1, z0     ) |
                         TMP_FETCH( x0    , y1, z0     ) |
                         TMP_FETCH( x0 + 1, y1, z0     ) |
                         TMP_FETCH( x0 - 1, y1, z0 + 1 ) |
                         TMP_FETCH( x0    , y1, z0 + 1 ) |
                         TMP_FETCH( x0 + 1, y1, z0 + 1 );
            break;
        }
        case 2: //-+z
        {
            /**
             * @verbatim
             *   +---+---+---+  y
             *   | 6 | 7 | 8 |  ^ z
             *   +---+---+---+  |/
             *   | 3 | 4 | 5 |  +--> x
             *   +---+---+---+
             *   | 0 | 1 | 2 |
             *   +---+---+---+
             * @endverbatim
             */
            uint32_t const z1 = z0 + shift;
            isOccupied = TMP_FETCH( x0 - 1, y0 - 1, z1 ) | /* 0 */
                         TMP_FETCH( x0    , y0 - 1, z1 ) | /* 1 */
                         TMP_FETCH( x0 + 1, y0 - 1, z1 ) | /* 2 */
                         TMP_FETCH( x0 - 1, y0    , z1 ) | /* 3 */
                         TMP_FETCH( x0    , y0    , z1 ) | /* 4 */
                         TMP_FETCH( x0 + 1, y0    , z1 ) | /* 5 */
                         TMP_FETCH( x0 - 1, y0 + 1, z1 ) | /* 6 */
                         TMP_FETCH( x0    , y0 + 1, z1 ) | /* 7 */
                         TMP_FETCH( x0 + 1, y0 + 1, z1 );  /* 8 */
            break;
        }
        #undef TMP_FETCH
    }
#else
    uint32_t const x0Abs  =   ( x0     ) & dcBoxXM1;
    uint32_t const x0PDX  =   ( x0 + 1 ) & dcBoxXM1;
    uint32_t const x0MDX  =   ( x0 - 1 ) & dcBoxXM1;
    uint32_t const y0Abs  = ( ( y0     ) & dcBoxYM1 ) << dcBoxXLog2;
    uint32_t const y0PDY  = ( ( y0 + 1 ) & dcBoxYM1 ) << dcBoxXLog2;
    uint32_t const y0MDY  = ( ( y0 - 1 ) & dcBoxYM1 ) << dcBoxXLog2;
    uint32_t const z0Abs  = ( ( z0     ) & dcBoxZM1 ) << dcBoxXYLog2;
    uint32_t const z0PDZ  = ( ( z0 + 1 ) & dcBoxZM1 ) << dcBoxXYLog2;
    uint32_t const z0MDZ  = ( ( z0 - 1 ) & dcBoxZM1 ) << dcBoxXYLog2;

    intCUDA const dx = DXTable_d[ axis ];   // 2*axis-1
    intCUDA const dy = DYTable_d[ axis ];   // 2*(axis&1)-1
    intCUDA const dz = DZTable_d[ axis ];   // 2*(axis&1)-1
    switch ( axis >> 1 )
    {
        case 0: //-+x
        {
            uint32_t const x1 = ( x0 + 2*dx ) & dcBoxXM1;
            isOccupied =
                tex1Dfetch< uint8_t >( texLattice, x1 + y0MDY + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0Abs + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0PDY + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0MDY + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0Abs + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0PDY + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0MDY + z0PDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0Abs + z0PDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x1 + y0PDY + z0PDZ );
            break;
        }
        case 1: //-+y
        {
            uint32_t const y1 = ( ( y0 + 2*dy ) & dcBoxYM1 ) << dcBoxXLog2;
            isOccupied =
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y1 + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y1 + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y1 + z0MDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y1 + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y1 + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y1 + z0Abs ) |
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y1 + z0PDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y1 + z0PDZ ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y1 + z0PDZ );
            break;
        }
        case 2: //-+z
        {
            uint32_t const z1 = ( ( z0 + 2*dz ) & dcBoxZM1 ) << dcBoxXYLog2;
            isOccupied =
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y0MDY + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y0MDY + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y0MDY + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y0Abs + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y0Abs + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y0Abs + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0MDX + y0PDY + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0Abs + y0PDY + z1 ) |
                tex1Dfetch< uint8_t >( texLattice, x0PDX + y0PDY + z1 );
            break;
        }
    }
#endif
    return isOccupied;
}

__device__ __host__ inline uintCUDA linearizeBondVectorIndex
(
    intCUDA const x,
    intCUDA const y,
    intCUDA const z
)
{
    /* Just like for normal integers we clip the range to go more down than up
     * i.e. [-127 ,128] or in this case [-4,3]
     * +4 maps to the same location as -4 but is needed or else forbidden
     * bonds couldn't be detected. Larger bonds are not possible, because
     * monomers only move by 1 per step */
    //assert( -4 <= x && x <= 4 );
    //assert( -4 <= y && y <= 4 );
    //assert( -4 <= z && z <= 4 );
    return   ( x & 7 /* 0b111 */ ) +
           ( ( y & 7 /* 0b111 */ ) << 3 ) +
           ( ( z & 7 /* 0b111 */ ) << 6 );
}

/**
 * Goes over all monomers of a species given specified by texSpeciesIndices
 * draws a random direction for them and checks whether that move is possible
 * with the box size and periodicity as well as the monomers at the target
 * location (excluded volume) and the new bond lengths to all neighbors.
 * If so, then the new position is set to 1 in dpLatticeTmp and encode the
 * possible movement direction in the property tag of the corresponding monomer
 * in dpPolymerSystem.
 * Note that the old position is not removed in order to correctly check for
 * excluded volume a second time.
 *
 * @param[in] rn a random number used as a kind of seed for the RNG
 * @param[in] nMonomers number of max. monomers to work on, this is for
 *            filtering out excessive threads and was prior a __constant__
 *            But it is only used one(!) time in the kernel so the caching
 *            of constant memory might not even be used.
 *            @see https://web.archive.org/web/20140612185804/http://www.pixel.io/blog/2013/5/9/kernel-arguments-vs-__constant__-variables.html
 *            -> Kernel arguments are even put into constant memory it seems:
 *            @see "Section E.2.5.2 Function Parameters" in the "CUDA 5.5 C Programming Guide"
 *            __global__ function parameters are passed to the device:
 *             - via shared memory and are limited to 256 bytes on devices of compute capability 1.x,
 *             - via constant memory and are limited to 4 KB on devices of compute capability 2.x and higher.
 *            __device__ and __global__ functions cannot have a variable number of arguments.
 * Note: all of the three kernels do quite few work. They basically just fetch
 *       data, and check one condition and write out again. There isn't even
 *       a loop and most of the work seems to be boiler plate initialization
 *       code which could be cut if the kernels could be merged together.
 *       Why are there three kernels instead of just one
 *        -> for global synchronization
 */
using T_Flags = UpdaterGPUScBFM_AB_Type::T_Flags;
__global__ void kernelSimulationScBFMCheckSpecies
(
    intCUDA           * const dpPolymerSystem        ,
    T_Flags           * const dpPolymerFlags         ,
    uint32_t            const iOffset                ,
    uint8_t           * const dpLatticeTmp           ,
    uint32_t          * const dpNeighbors            ,
    uint32_t            const rNeighborsPitchElements,
    uint32_t            const nMonomers              ,
    uint32_t            const rSeed                  ,
    cudaTextureObject_t const texLatticeRefOut
)
{
    int const iMonomer = blockIdx.x * blockDim.x + threadIdx.x;
    if ( iMonomer >= nMonomers )
        return;

    auto const data = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iOffset + iMonomer ];
    intCUDA const & x0         = data.x;
    intCUDA const & y0         = data.y;
    intCUDA const & z0         = data.z;

    //select random direction. Own implementation of an rng :S? But I think it at least# was initialized using the LeMonADE RNG ...
    uintCUDA const direction = hash( hash( iMonomer ) ^ rSeed ) % 6;

     /* select random direction. Do this with bitmasking instead of lookup ??? */
    intCUDA const dx = DXTable_d[ direction ];
    intCUDA const dy = DYTable_d[ direction ];
    intCUDA const dz = DZTable_d[ direction ];

    dpPolymerFlags[ iMonomer + iOffset ] = 0;

#ifdef NONPERIODICITY
   /* check whether the new location of the particle would be inside the box
    * if the box is not periodic, if not, then don't move the particle */
    if ( ! ( 0 <= x0 + dx && x0 + dx < dcBoxXM1 &&
             0 <= y0 + dy && y0 + dy < dcBoxYM1 &&
             0 <= z0 + dz && z0 + dz < dcBoxZM1 ) )
    {
        return;
    }
#endif
    /* check whether the new position would result in invalid bonds
     * between this monomer and its neighbors */
    unsigned const nNeighbors = ( data.w >> 5 ) & 7; // 7=0b111
    for ( unsigned iNeighbor = 0; iNeighbor < nNeighbors; ++iNeighbor )
    {
        auto const iGlobalNeighbor = dpNeighbors[ iNeighbor * rNeighborsPitchElements + iMonomer ];
        auto const data2 = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iGlobalNeighbor ];
        if ( dpForbiddenBonds[ linearizeBondVectorIndex( data2.x - x0 - dx, data2.y - y0 - dy, data2.z - z0 - dz ) ] )
            return;
    }

    if ( checkFront( texLatticeRefOut, x0, y0, z0, direction ) )
        return;

    /* everything fits so perform move on temporary lattice */
    /* can I do this ??? dpPolymerSystem is the device pointer to the read-only
     * texture used above. Won't this result in read-after-write race-conditions?
     * Then again the written / changed bits are never used in the above code ... */
    dpPolymerFlags[ iMonomer + iOffset ] = ( direction << 2 ) + 1 /* can-move-flag */;
    dpLatticeTmp[ linearizeBoxVectorIndex( x0+dx, y0+dy, z0+dz ) ] = 1;
}


__global__ void kernelCountFilteredCheck
(
    intCUDA           * const dpPolymerSystem        ,
    T_Flags           * const dpPolymerFlags         ,
    uint32_t            const iOffset                ,
    uint8_t           * const /* dpLatticeTmp */     ,
    uint32_t          * const dpNeighbors            ,
    uint32_t            const rNeighborsPitchElements,
    uint32_t            const nMonomers              ,
    uint32_t            const rSeed                  ,
    cudaTextureObject_t const texLatticeRefOut       ,
    unsigned long long int * const dpFiltered
)
{
    int const iMonomer = blockIdx.x * blockDim.x + threadIdx.x;
    if ( iMonomer >= nMonomers )
        return;

    auto const data = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iOffset + iMonomer ];
    intCUDA const & x0         = data.x;
    intCUDA const & y0         = data.y;
    intCUDA const & z0         = data.z;
    auto const properties = dpPolymerFlags[ iOffset + iMonomer ];
    //select random direction. Own implementation of an rng :S? But I think it at least# was initialized using the LeMonADE RNG ...
    uintCUDA const direction = hash( hash( iMonomer ) ^ rSeed ) % 6;

     /* select random direction. Do this with bitmasking instead of lookup ??? */
    intCUDA const dx = DXTable_d[ direction ];
    intCUDA const dy = DYTable_d[ direction ];
    intCUDA const dz = DZTable_d[ direction ];

#ifdef NONPERIODICITY
   /* check whether the new location of the particle would be inside the box
    * if the box is not periodic, if not, then don't move the particle */
    if ( ! ( 0 <= x0 + dx && x0 + dx < dcBoxXM1 &&
             0 <= y0 + dy && y0 + dy < dcBoxYM1 &&
             0 <= z0 + dz && z0 + dz < dcBoxZM1 ) )
    {
        atomicAdd( dpFiltered+0, size_t(1) );
    }
#endif
    /* check whether the new position would result in invalid bonds
     * between this monomer and its neighbors */
    unsigned const nNeighbors = ( data.w >> 5 ) & 7; // 7=0b111
    bool invalidBond = false;
    for ( unsigned iNeighbor = 0; iNeighbor < nNeighbors; ++iNeighbor )
    {
        auto const iGlobalNeighbor = dpNeighbors[ iNeighbor * rNeighborsPitchElements + iMonomer ];
        auto const data2 = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iGlobalNeighbor ];
        if ( dpForbiddenBonds[ linearizeBondVectorIndex( data2.x - x0 - dx, data2.y - y0 - dy, data2.z - z0 - dz ) ] )
        {
            atomicAdd( dpFiltered+1, 1 );
            invalidBond = true;
            break;
        }
    }

    if ( checkFront( texLatticeRefOut, x0, y0, z0, direction ) )
    {
        atomicAdd( dpFiltered+2, 1 );
        if ( ! invalidBond ) /* this is the more real relative use-case where invalid bonds are already filtered out */
            atomicAdd( dpFiltered+3, 1 );
    }
}


/**
 * Recheck whether the move is possible without collision, using the
 * temporarily parallel executed moves saved in texLatticeTmp. If so,
 * do the move in dpLattice. (Still not applied in dpPolymerSystem!)
 */
__global__ void kernelSimulationScBFMPerformSpecies
(
    intCUDA             * const dpPolymerSystem  ,
    T_Flags             * const dpPolymerFlags   ,
    uint8_t             * const dpLattice        ,
    uint32_t              const nMonomers        ,
    cudaTextureObject_t   const texLatticeTmp
)
{
    int const iMonomer = blockIdx.x * blockDim.x + threadIdx.x;
    if ( iMonomer >= nMonomers )
        return;

    auto data = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iMonomer ];
    intCUDA & x0         = data.x;
    intCUDA & y0         = data.y;
    intCUDA & z0         = data.z;
    auto const properties = dpPolymerFlags[ iMonomer ];
    if ( ( properties & 1 ) == 0 )    // impossible move
        return;

    uintCUDA const direction = ( properties >> 2 ) & 7; // 7=0b111

    intCUDA const dx = DXTable_d[ direction ];
    intCUDA const dy = DYTable_d[ direction ];
    intCUDA const dz = DZTable_d[ direction ];

    if ( checkFront( texLatticeTmp, x0, y0, z0, direction ) )
        return;

    /* If possible, perform move now on normal lattice */
    dpPolymerFlags[ iMonomer ] = properties | 2; // indicating allowed move
    dpLattice[ linearizeBoxVectorIndex( x0+dx, y0+dy, z0+dz ) ] = 1;
    dpLattice[ linearizeBoxVectorIndex( x0   , y0   , z0    ) ] = 0;
    /* We can't clean the temporary lattice in here, because it still is being
     * used for checks. For cleaning we need only the new positions.
     * But we can't use the applied positions, because we also need to clean
     * those particles which couldn't move in this second kernel but where
     * still set in the lattice by the first kernel! */
}

__global__ void kernelCountFilteredPerform
(
    intCUDA             * const dpPolymerSystem  ,
    T_Flags             * const dpPolymerFlags   ,
    uint8_t             * const /* dpLattice */  ,
    uint32_t              const nMonomers        ,
    cudaTextureObject_t   const texLatticeTmp    ,
    unsigned long long int * const dpFiltered
)
{
    int const iMonomer = blockIdx.x * blockDim.x + threadIdx.x;
    if ( iMonomer >= nMonomers )
        return;

    auto data = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iMonomer ];
    auto const properties = dpPolymerFlags[ iMonomer ];
    if ( ( properties & 1 ) == 0 )    // impossible move
        return;

    uintCUDA const direction = ( properties >> 2 ) & 7; // 7=0b111
    if ( checkFront( texLatticeTmp, data.x, data.y, data.z, direction ) )
        atomicAdd( dpFiltered+4, size_t(1) );
}

/**
 * Apply move to dpPolymerSystem and clean the temporary lattice of moves
 * which seemed like they would work, but did clash with another parallel
 * move, unfortunately.
 * @todo it might be better to just use a cudaMemset to clean the lattice,
 *       that way there wouldn't be any memory dependencies and calculations
 *       needed, even though we would have to clean everything, instead of
 *       just those set. But that doesn't matter, because most of the threads
 *       are idling anyway ...
 *       This kind of kernel might give some speedup after stream compaction
 *       has been implemented though.
 *    -> print out how many percent of cells need to be cleaned .. I need
 *       many more statistics anyway for evaluating performance benefits a bit
 *       better!
 */
__global__ void kernelSimulationScBFMZeroArraySpecies
(
    intCUDA             * const dpPolymerSystem,
    T_Flags             * const dpPolymerFlags ,
    uint8_t             * const dpLatticeTmp   ,
    uint32_t              const nMonomers
)
{
    int const iMonomer = blockIdx.x * blockDim.x + threadIdx.x;
    if ( iMonomer >= nMonomers )
        return;

    auto data = ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iMonomer ];
    intCUDA & x0         = data.x;
    intCUDA & y0         = data.y;
    intCUDA & z0         = data.z;
    auto const properties = dpPolymerFlags[ iMonomer ];

    if ( ( properties & 3 ) == 0 )    // impossible move
        return;

    uintCUDA const direction = ( properties >> 2 ) & 7; // 7=0b111
    intCUDA const dx = DXTable_d[ direction ];
    intCUDA const dy = DYTable_d[ direction ];
    intCUDA const dz = DZTable_d[ direction ];

    dpLatticeTmp[ linearizeBoxVectorIndex( x0+dx, y0+dy, z0+dz ) ] = 0;
    /* possible move which clashes with another parallely moved monomer
     * Clean up the temporary lattice with these moves. */
    if ( ( properties & 3 ) == 3 )  // 3=0b11
    {
        x0 += dx;
        y0 += dy;
        z0 += dz;
    }
    ( (intCUDAVec< intCUDA >::value_type *) dpPolymerSystem )[ iMonomer ] = data;
}


UpdaterGPUScBFM_AB_Type::UpdaterGPUScBFM_AB_Type()
 : mStream              ( 0 ),
   nAllMonomers         ( 0 ),
   mLattice             ( NULL ),
   mLatticeOut          ( NULL ),
   mLatticeTmp          ( NULL ),
   mPolymerSystemSorted ( NULL ),
   mPolymerFlags        ( NULL ),
   mNeighborsSorted     ( NULL ),
   mNeighborsSortedInfo ( nBytesAlignment ),
   mAttributeSystem     ( NULL ),
   mBoxX                ( 0 ),
   mBoxY                ( 0 ),
   mBoxZ                ( 0 ),
   mBoxXM1              ( 0 ),
   mBoxYM1              ( 0 ),
   mBoxZM1              ( 0 ),
   mBoxXLog2            ( 0 ),
   mBoxXYLog2           ( 0 )
{
    /**
     * Log control.
     * Note that "Check" controls not the output, but the actualy checks
     * If a checks needs to always be done, then do that check and declare
     * the output as "Info" log level
     */
    mLog.file( __FILENAME__ );
    mLog.  activate( "Benchmark" );
    mLog.deactivate( "Check"     );
    mLog.  activate( "Error"     );
    mLog.  activate( "Info"      );
    mLog.deactivate( "Stats"     );
    mLog.deactivate( "Warning"   );
}

/**
 * Deletes everything which could and is allocated
 */
void UpdaterGPUScBFM_AB_Type::destruct()
{
    if ( mLattice         != NULL ){ delete[] mLattice        ; mLattice         = NULL; }  // setLatticeSize
    if ( mLatticeOut      != NULL ){ delete   mLatticeOut     ; mLatticeOut      = NULL; }  // initialize
    if ( mLatticeTmp      != NULL ){ delete   mLatticeTmp     ; mLatticeTmp      = NULL; }  // initialize
    if ( mPolymerSystemSorted != NULL ){ delete mPolymerSystemSorted; mPolymerSystemSorted = NULL; }  // initialize
    if ( mPolymerFlags    != NULL ){ delete   mPolymerFlags   ; mPolymerFlags    = NULL; }  // initialize
    if ( mNeighborsSorted != NULL ){ delete   mNeighborsSorted; mNeighborsSorted = NULL; }  // initialize
    if ( mAttributeSystem != NULL ){ delete[] mAttributeSystem; mAttributeSystem = NULL; }  // setNrOfAllMonomers
}

UpdaterGPUScBFM_AB_Type::~UpdaterGPUScBFM_AB_Type()
{
    this->destruct();
}

void UpdaterGPUScBFM_AB_Type::setGpu( int iGpuToUse )
{
    int nGpus;
    getCudaDeviceProperties( NULL, &nGpus, true /* print GPU information */ );
    if ( ! ( 0 <= iGpuToUse && iGpuToUse < nGpus ) )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setGpu] "
            << "GPU with ID " << iGpuToUse << " not present. "
            << "Only " << nGpus << " GPUs are available.\n";
        mLog( "Error" ) << msg.str();
        throw std::invalid_argument( msg.str() );
    }
    CUDA_ERROR( cudaSetDevice( iGpuToUse ));
}


void UpdaterGPUScBFM_AB_Type::initialize( void )
{
    if ( mLog( "Stats" ).isActive() )
    {
        // this is called in parallel it seems, therefore need to buffer it
        std::stringstream msg; msg
        << "[" << __FILENAME__ << "::initialize] The "
        << "(" << mBoxX << "," << mBoxY << "," << mBoxZ << ")"
        << " lattice is populated by " << nAllMonomers
        << " resulting in a filling rate of "
        << nAllMonomers / double( mBoxX * mBoxY * mBoxZ ) << "\n";
        mLog( "Stats" ) << msg.str();
    }

    if ( mLatticeOut != NULL || mLatticeTmp != NULL )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::initialize] "
            << "Initialize was already called and may not be called again "
            << "until cleanup was called!";
        mLog( "Error" ) << msg.str();
        throw std::runtime_error( msg.str() );
    }

    /* create the BondTable and copy it to constant memory */
    bool * tmpForbiddenBonds = (bool*) malloc( sizeof( bool ) * 512 );
    unsigned nAllowedBonds = 0;
    for ( int i = 0; i < 512; ++i )
        if ( ! ( tmpForbiddenBonds[i] = mForbiddenBonds[i] ) )
            ++nAllowedBonds;
    /* Why does it matter? Shouldn't it work with arbitrary bond sets ??? */
    if ( nAllowedBonds != 108 )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::initialize] "
            << "Wrong bond-set! Expected 108 allowed bonds, but got " << nAllowedBonds << "\n";
        mLog( "Error" ) << msg.str();
        throw std::runtime_error( msg.str() );
    }
    CUDA_ERROR( cudaMemcpyToSymbol( dpForbiddenBonds, tmpForbiddenBonds, sizeof(bool)*512 ) );
    free( tmpForbiddenBonds );

    /* create a table mapping the random int to directions whereto move the monomers */
    intCUDA tmp_DXTable[6] = { -1,1,  0,0,  0,0 };
    intCUDA tmp_DYTable[6] = {  0,0, -1,1,  0,0 };
    intCUDA tmp_DZTable[6] = {  0,0,  0,0, -1,1 };
    CUDA_ERROR( cudaMemcpyToSymbol( DXTable_d, tmp_DXTable, sizeof( intCUDA ) * 6 ) );
    CUDA_ERROR( cudaMemcpyToSymbol( DYTable_d, tmp_DYTable, sizeof( intCUDA ) * 6 ) );
    CUDA_ERROR( cudaMemcpyToSymbol( DZTable_d, tmp_DZTable, sizeof( intCUDA ) * 6 ) );

    /*************************** start of grouping ***************************/

   mLog( "Info" ) << "Coloring graph ...\n";
    bool const bUniformColors = true; // setting this to true should yield more performance as the kernels are uniformly utilized
    mGroupIds = graphColoring< MonomerEdges const *, uint32_t, uint8_t >(
        &mNeighbors[0], mNeighbors.size(), bUniformColors,
        []( MonomerEdges const * const & x, uint32_t const & i ){ return x[i].size; },
        []( MonomerEdges const * const & x, uint32_t const & i, size_t const & j ){ return x[i].neighborIds[j]; }
    );

    /* check automatic coloring with that given in BFM-file */
    if ( mLog.isActive( "Check" ) )
    {
        mLog( "Info" ) << "Checking difference between automatic and given coloring ... ";
        size_t nDifferent = 0;
        for ( size_t iMonomer = 0u; iMonomer < std::max( (uint32_t) 20, this->nAllMonomers ); ++iMonomer )
        {
            if ( mGroupIds.at( iMonomer )+1 != mAttributeSystem[ iMonomer ] )
            {
                 mLog( "Info" ) << "Color of " << iMonomer << " is automatically " << mGroupIds.at( iMonomer )+1 << " vs. " << mAttributeSystem[ iMonomer ] << "\n";
                ++nDifferent;
            }
        }
        if ( nDifferent > 0 )
        {
            std::stringstream msg;
            msg << "Automatic coloring failed to produce same result as the given one!";
            mLog( "Error" ) << msg.str();
            throw std::runtime_error( msg.str() );
        }
        mLog( "Info" ) << "OK\n";
    }

    /* count monomers per species before allocating per species arrays and
     * sorting the monomers into them */
    mLog( "Info" ) << "Attributes of first monomers: ";
    mnElementsInGroup.resize(0);
    for ( size_t i = 0u; i < mGroupIds.size(); ++i )
    {
        if ( i < 40 )
            mLog( "Info" ) << char( 'A' + (char) mGroupIds[i] );
        if ( mGroupIds[i] >= mnElementsInGroup.size() )
            mnElementsInGroup.resize( mGroupIds[i]+1, 0 );
        ++mnElementsInGroup[ mGroupIds[i] ];
    }
    mLog( "Info" ) << "\n";
    if ( mLog.isActive( "Stats" ) )
    {
        mLog( "Stats" ) << "Found " << mnElementsInGroup.size() << " groups with the frequencies: ";
        for ( size_t i = 0u; i < mnElementsInGroup.size(); ++i )
        {
            mLog( "Stats" ) << char( 'A' + (char) i ) << ": " << mnElementsInGroup[i] << "x (" << (float) mnElementsInGroup[i] / nAllMonomers * 100.f << "%), ";
        }
        mLog( "Stats" ) << "\n";
    }

    /**
     * Generate new array which contains all sorted monomers aligned
     * @verbatim
     * ABABABABABA
     * A A A A A A
     *  B B B B B
     * AAAAAA  BBBBB
     *        ^ alignment
     * @endverbatim
     * in the worst case we are only one element ( 4*intCUDA ) over the
     * alignment with each group and need to fill up to nBytesAlignment for
     * all of them */
    /* virtual number of monomers which includes the additional alignment padding */
    auto const nMonomersPadded = nAllMonomers + ( nElementsAlignment - 1u ) * mnElementsInGroup.size();
    assert( mPolymerFlags == NULL );
    mPolymerFlags = new MirroredVector< T_Flags >( nMonomersPadded, mStream );
    /* Calculate offsets / prefix sum including the alignment */
    assert( mPolymerSystemSorted == NULL );
    mPolymerSystemSorted = new MirroredVector< intCUDA >( 4u * nMonomersPadded, mStream );
    #ifndef NDEBUG
        std::memset( mPolymerSystemSorted.host, 0, mPolymerSystemSorted.nBytes );
    #endif

    /* calculate offsets to each aligned subgroup vector */
    iSubGroupOffset.resize( mnElementsInGroup.size() );
    iSubGroupOffset.at(0) = 0;
    for ( size_t i = 1u; i < mnElementsInGroup.size(); ++i )
    {
        iSubGroupOffset[i] = iSubGroupOffset[i-1] +
        ceilDiv( mnElementsInGroup[i-1], nElementsAlignment ) * nElementsAlignment;
        assert( iSubGroupOffset[i] - iSubGroupOffset[i-1] >= mnElementsInGroup[i-1] );
    }

    /* virtually sort groups into new array and save index mappings */
    iToiNew.resize( nAllMonomers   , UINT32_MAX );
    iNewToi.resize( nMonomersPadded, UINT32_MAX );
    std::vector< size_t > iSubGroup = iSubGroupOffset;   /* stores the next free index for each subgroup */
    for ( size_t i = 0u; i < nAllMonomers; ++i )
    {
        iToiNew[i] = iSubGroup[ mGroupIds[i] ]++;
        iNewToi[ iToiNew[i] ] = i;
    }

    if ( mLog.isActive( "Info" ) )
    {
        mLog( "Info" ) << "iSubGroupOffset = { ";
        for ( auto const & x : iSubGroupOffset )
            mLog( "Info" ) << x << ", ";
        mLog( "Info" ) << "}\n";

        mLog( "Info" ) << "iSubGroup = { ";
        for ( auto const & x : iSubGroup )
            mLog( "Info" ) << x << ", ";
        mLog( "Info" ) << "}\n";

        mLog( "Info" ) << "mnElementsInGroup = { ";
        for ( auto const & x : mnElementsInGroup )
            mLog( "Info" ) << x << ", ";
        mLog( "Info" ) << "}\n";
    }

    /* adjust neighbor IDs to new sorted PolymerSystem and also sort that array.
     * Bonds are not supposed to change, therefore we don't need to push and
     * pop them each time we do something on the GPU! */
    assert( mNeighborsSorted == NULL );
    assert( mNeighborsSortedInfo.getRequiredBytes() == 0 );
    for ( size_t i = 0u; i < mnElementsInGroup.size(); ++i )
        mNeighborsSortedInfo.newMatrix( MAX_CONNECTIVITY, mnElementsInGroup[i] );
    mNeighborsSorted = new MirroredVector< uint32_t >( mNeighborsSortedInfo.getRequiredElements(), mStream );
    std::memset( mNeighborsSorted->host, 0, mNeighborsSorted->nBytes );

    if ( mLog.isActive( "Info" ) )
    {
        mLog( "Info" )
        << "Allocated mNeighborsSorted with "
        << mNeighborsSorted->nElements << " elements in "
        << mNeighborsSorted->nBytes << "B ("
        << mNeighborsSortedInfo.getRequiredElements() << ","
        << mNeighborsSortedInfo.getRequiredBytes() << "B)\n";

        mLog( "Info" ) << "mNeighborsSortedInfo:\n";
        for ( size_t iSpecies = 0u; iSpecies < mnElementsInGroup.size(); ++iSpecies )
        {
            mLog( "Info" )
            << "== matrix/species " << iSpecies << " ==\n"
            << "offset:" << mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ) << " elements = "
                         << mNeighborsSortedInfo.getMatrixOffsetBytes   ( iSpecies ) << "B\n"
            //<< "rows  :" << mNeighborsSortedInfo.getOffsetElements() << " elements = "
            //             << mNeighborsSortedInfo.getOffsetBytes() << "B\n"
            //<< "cols  :" << mNeighborsSortedInfo.getOffsetElements() << " elements = "
            //             << mNeighborsSortedInfo.getOffsetBytes() << "B\n"
            << "pitch :" << mNeighborsSortedInfo.getMatrixPitchElements( iSpecies ) << " elements = "
                         << mNeighborsSortedInfo.getMatrixPitchBytes   ( iSpecies ) << "B\n";
        }
        mLog( "Info" ) << "[UpdaterGPUScBFM_AB_Type::runSimulationOnGPU] map neighborIds to sorted array ... ";
    }

    {
        size_t iSpecies = 0u;
        /* iterate over sorted instead of unsorted array so that calculating
         * the current species we are working on is easier */
        for ( size_t i = 0u; i < iNewToi.size(); ++i )
        {
            /* check if we are already working on a new species */
            if ( iSpecies+1 < iSubGroupOffset.size() &&
                 i >= iSubGroupOffset[ iSpecies+1 ] )
            {
                mLog( "Info" ) << "Currently at index " << i << "/" << iNewToi.size() << " and crossed offset of species " << iSpecies+1 << " at " << iSubGroupOffset[ iSpecies+1 ] << " therefore incrementing iSpecies\n";
                ++iSpecies;
            }
            /* skip over padded indices */
            if ( iNewToi[i] >= nAllMonomers )
                continue;
            /* actually to the sorting / copying and conversion */
            auto const pitch = mNeighborsSortedInfo.getMatrixPitchElements( iSpecies );
            for ( size_t j = 0u; j < mNeighbors[  iNewToi[i] ].size; ++j )
            {
                if ( i < 5 || std::abs( (long long int) i - iSubGroupOffset[ iSubGroupOffset.size()-1 ] ) < 5 )
                {
                    mLog( "Info" ) << "Currently at index " << i << ": Writing into mNeighborsSorted->host[ " << mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ) << " + " << j << " * " << pitch << " + " << i << "-" << iSubGroupOffset[ iSpecies ] << "] the value of old neighbor located at iToiNew[ mNeighbors[ iNewToi[i]=" << iNewToi[i] << " ] = iToiNew[ " << mNeighbors[ iNewToi[i] ].neighborIds[j] << " ] = " << iToiNew[ mNeighbors[ iNewToi[i] ].neighborIds[j] ] << " \n";
                }
                mNeighborsSorted->host[ mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ) + j * pitch + ( i - iSubGroupOffset[ iSpecies ] ) ] = iToiNew[ mNeighbors[ iNewToi[i] ].neighborIds[j] ];
                //mNeighborsSorted->host[ iToiNew[i] ].neighborIds[j] = iToiNew[ mNeighbors[i].neighborIds[j] ];
            }
        }
    }
    mNeighborsSorted->pushAsync();
    mLog( "Info" ) << "Done\n";

    /* some checks for correctness of new adjusted neighbor global IDs */
    if ( mLog.isActive( "Check" ) )
    {
        /* note that this also checks "unitialized entries" those should be
         * initialized to 0 to reduce problems. This is done by the memset. */
        /*for ( size_t i = 0u; i < mNeighborsSorted->nElements; ++i )
        {
            if ( mNeighbors[i].size > MAX_CONNECTIVITY )
                throw std::runtime_error( "A monomer has more neighbors than allowed!" );
            for ( size_t j = 0u; j < mNeighbors[i].size; ++j )
            {
                auto const iSorted = mNeighborsSorted->host[i].neighborIds[j];
                if ( iSorted == UINT32_MAX )
                    throw std::runtime_error( "New index mapping not set!" );
                if ( iSorted >= nMonomersPadded )
                    throw std::runtime_error( "New index out of range!" );
            }
        }*/
        /* does a similar check for the unsorted error which is still used
         * to create the property tag */
        for ( uint32_t i = 0; i < nAllMonomers; ++i )
        {
            if ( mNeighbors[i].size > MAX_CONNECTIVITY )
            {
                std::stringstream msg;
                msg << "[" << __FILENAME__ << "::initialize] "
                    << "This implementation allows max. 7 neighbors per monomer, "
                    << "but monomer " << i << " has " << mNeighbors[i].size << "\n";
                mLog( "Error" ) << msg.str();
                throw std::invalid_argument( msg.str() );
            }
        }
    }

    /************************** end of group sorting **************************/

    /* add property tags for each monomer with number of neighbor information */
    for ( uint32_t i = 0; i < nAllMonomers; ++i )
        mPolymerSystem[ 4*i+3 ] |= ( (intCUDA) mNeighbors[i].size ) << 5;

    /* sort groups into new array and save index mappings */
    mLog( "Info" ) << "[UpdaterGPUScBFM_AB_Type::runSimulationOnGPU] sort mPolymerSystem -> mPolymerSystemSorted ... ";
    for ( size_t i = 0u; i < nAllMonomers; ++i )
    {
        if ( i < 20 )
            mLog( "Info" ) << "Write " << i << " to " << this->iToiNew[i] << "\n";
        auto const pTarget = mPolymerSystemSorted->host + 4*iToiNew[i];
        pTarget[0] = mPolymerSystem[4*i+0];
        pTarget[1] = mPolymerSystem[4*i+1];
        pTarget[2] = mPolymerSystem[4*i+2];
        pTarget[3] = mPolymerSystem[4*i+3];
    }
    mPolymerSystemSorted->pushAsync();

    checkSystem();

    /* creating lattice */
    CUDA_ERROR( cudaMemcpyToSymbol( dcBoxXM1   , &mBoxXM1   , sizeof( mBoxXM1    ) ) );
    CUDA_ERROR( cudaMemcpyToSymbol( dcBoxYM1   , &mBoxYM1   , sizeof( mBoxYM1    ) ) );
    CUDA_ERROR( cudaMemcpyToSymbol( dcBoxZM1   , &mBoxZM1   , sizeof( mBoxZM1    ) ) );
    CUDA_ERROR( cudaMemcpyToSymbol( dcBoxXLog2 , &mBoxXLog2 , sizeof( mBoxXLog2  ) ) );
    CUDA_ERROR( cudaMemcpyToSymbol( dcBoxXYLog2, &mBoxXYLog2, sizeof( mBoxXYLog2 ) ) );

    mLatticeOut = new MirroredTexture< uint8_t >( mBoxX * mBoxY * mBoxZ, mStream );
    mLatticeTmp = new MirroredTexture< uint8_t >( mBoxX * mBoxY * mBoxZ, mStream );
    CUDA_ERROR( cudaMemsetAsync( mLatticeTmp->gpu, 0, mLatticeTmp->nBytes, mStream ) );
    /* populate latticeOut with monomers from mPolymerSystem */
    std::memset( mLatticeOut->host, 0, mLatticeOut->nBytes );
    for ( uint32_t t = 0; t < nAllMonomers; ++t )
    {
        #ifdef USEZCURVE
            uint32_t xk = mPolymerSystem[ 4*t+0 ] & mBoxXM1;
            uint32_t yk = mPolymerSystem[ 4*t+1 ] & mBoxYM1;
            uint32_t zk = mPolymerSystem[ 4*t+2 ] & mBoxZM1;
            uint32_t inter3 = interleave3( xk/2 , yk/2, zk/2 );
            mLatticeOut_host[ ( ( mPolymerSystem[ 4*t+3 ] & 1 ) << 23 ) + inter3 ] = 1;
        #else
        mLatticeOut->host[ linearizeBoxVectorIndex( mPolymerSystem[ 4*t+0 ],
                                                    mPolymerSystem[ 4*t+1 ],
                                                    mPolymerSystem[ 4*t+2 ] ) ] = 1;
        #endif
    }
    mLatticeOut->pushAsync();

    mLog( "Info" )
        << "Filling Rate: " << nAllMonomers << " "
        << "(=" << nAllMonomers / 1024 << "*1024+" << nAllMonomers % 1024 << ") "
        << "particles in a (" << mBoxX << "," << mBoxY << "," << mBoxZ << ") box "
        << "=> " << 100. * nAllMonomers / ( mBoxX * mBoxY * mBoxZ ) << "%\n"
        << "Note: densest packing is: 25% -> in this case it might be more reasonable to actually iterate over the spaces where particles can move to, keeping track of them instead of iterating over the particles\n";
}


void UpdaterGPUScBFM_AB_Type::copyBondSet
( int dx, int dy, int dz, bool bondForbidden )
{
    mForbiddenBonds[ linearizeBondVectorIndex(dx,dy,dz) ] = bondForbidden;
}

void UpdaterGPUScBFM_AB_Type::setNrOfAllMonomers( uint32_t const rnAllMonomers )
{
    if ( this->nAllMonomers != 0 || mAttributeSystem != NULL ||
         mPolymerSystemSorted != NULL || mNeighborsSorted != NULL )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setNrOfAllMonomers] "
            << "Number of Monomers already set to " << nAllMonomers << "!\n"
            << "Or some arrays were already allocated "
            << "(mAttributeSystem=" << (void*) mAttributeSystem
            << ", mPolymerSystemSorted" << (void*) mPolymerSystemSorted
            << ", mNeighborsSorted" << (void*) mNeighborsSorted << ")\n";
        throw std::runtime_error( msg.str() );
    }

    this->nAllMonomers = rnAllMonomers;
    mAttributeSystem = new int32_t[ nAllMonomers ];
    if ( mAttributeSystem == NULL )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setNrOfAllMonomers] mAttributeSystem is still NULL after call to 'new int32_t[ " << nAllMonomers << " ]!\n";
        mLog( "Error" ) << msg.str();
        throw std::runtime_error( msg.str() );
    }
    mPolymerSystem.resize( nAllMonomers*4 );
    mNeighbors    .resize( nAllMonomers   );
    std::memset( &mNeighbors[0], 0, mNeighbors.size() * sizeof( mNeighbors[0] ) );
}

void UpdaterGPUScBFM_AB_Type::setPeriodicity
(
    bool const isPeriodicX,
    bool const isPeriodicY,
    bool const isPeriodicZ
)
{
    /* Compare inputs to hardcoded values. No ability yet to adjust dynamically */
#ifdef NONPERIODICITY
    if ( isPeriodicX || isPeriodicY || isPeriodicZ )
#else
    if ( ! isPeriodicX || ! isPeriodicY || ! isPeriodicZ )
#endif
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setPeriodicity" << "] "
            << "Simulation is intended to use completely "
        #ifdef NONPERIODICITY
            << "non-"
        #endif
            << "periodic boundary conditions, but setPeriodicity was called with "
            << "(" << isPeriodicX << "," << isPeriodicY << "," << isPeriodicZ << ")\n";
        mLog( "Error" ) << msg.str();
        throw std::invalid_argument( msg.str() );
    }
}

void UpdaterGPUScBFM_AB_Type::setAttribute( uint32_t i, int32_t attribute )
{
    #ifndef NDEBUG
        std::cerr << "[setAttribute] mAttributeSystem = " << (void*) mAttributeSystem << "\n";
        if ( mAttributeSystem == NULL )
            throw std::runtime_error( "[UpdaterGPUScBFM_AB_Type.h::setAttribute] mAttributeSystem is NULL! Did you call setNrOfAllMonomers, yet?" );
        std::cerr << "set " << i << " to attribute " << attribute << "\n";
        if ( ! ( i < nAllMonomers ) )
            throw std::invalid_argument( "[UpdaterGPUScBFM_AB_Type.h::setAttribute] i out of range!" );
    #endif
    mAttributeSystem[i] = attribute;
}

void UpdaterGPUScBFM_AB_Type::setMonomerCoordinates
(
    uint32_t const i,
    int32_t  const x,
    int32_t  const y,
    int32_t  const z
)
{
#if DEBUG_UPDATERGPUSCBFM_AB_TYPE > 1
    /* can I apply periodic modularity here to allow the full range ??? */
    if ( ! inRange< decltype( mPolymerSystem[0] ) >(x) ||
         ! inRange< decltype( mPolymerSystem[0] ) >(y) ||
         ! inRange< decltype( mPolymerSystem[0] ) >(z)    )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setMonomerCoordinates" << "] "
            << "One or more of the given coordinates "
            << "(" << x << "," << y << "," << z << ") "
            << "is larger than the internal integer data type for "
            << "representing positions allow! (" << std::numeric_limits< intCUDA >::min()
            << " <= size <= " << std::numeric_limits< intCUDA >::max() << ")";
        throw std::invalid_argument( msg.str() );
    }
#endif
    mPolymerSystem.at( 4*i+0 ) = x;
    mPolymerSystem.at( 4*i+1 ) = y;
    mPolymerSystem.at( 4*i+2 ) = z;
}

int32_t UpdaterGPUScBFM_AB_Type::getMonomerPositionInX( uint32_t i ){ return mPolymerSystem[ 4*i+0 ]; }
int32_t UpdaterGPUScBFM_AB_Type::getMonomerPositionInY( uint32_t i ){ return mPolymerSystem[ 4*i+1 ]; }
int32_t UpdaterGPUScBFM_AB_Type::getMonomerPositionInZ( uint32_t i ){ return mPolymerSystem[ 4*i+2 ]; }

void UpdaterGPUScBFM_AB_Type::setConnectivity
(
    uint32_t const iMonomer1,
    uint32_t const iMonomer2
)
{
    /* @todo add check whether the bond already exists */
    /* Could also add the inversio, but the bonds are a non-directional graph */
    auto const iNew = mNeighbors[ iMonomer1 ].size++;
    if ( iNew > MAX_CONNECTIVITY-1 )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setConnectivity" << "] "
            << "The maximum amount of bonds per monomer (" << MAX_CONNECTIVITY
            << ") has been exceeded!\n";
        throw std::invalid_argument( msg.str() );
    }
    mNeighbors[ iMonomer1 ].neighborIds[ iNew ] = iMonomer2;
}

void UpdaterGPUScBFM_AB_Type::setLatticeSize
(
    uint32_t const boxX,
    uint32_t const boxY,
    uint32_t const boxZ
)
{
    if ( mBoxX == boxX && mBoxY == boxY && mBoxZ == boxZ )
        return;

    if ( ! ( inRange< intCUDA >( boxX ) &&
             inRange< intCUDA >( boxY ) &&
             inRange< intCUDA >( boxZ )    ) )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setLatticeSize" << "] "
            << "The box size (" << boxX << "," << boxY << "," << boxZ
            << ") is larger than the internal integer data type for "
            << "representing positions allow! (" << std::numeric_limits< intCUDA >::min()
            << " <= size <= " << std::numeric_limits< intCUDA >::max() << ")";
        throw std::invalid_argument( msg.str() );
    }

    mBoxX   = boxX;
    mBoxY   = boxY;
    mBoxZ   = boxZ;
    mBoxXM1 = boxX-1;
    mBoxYM1 = boxY-1;
    mBoxZM1 = boxZ-1;

    /* determine log2 for mBoxX and mBoxX * mBoxY to be used for bitshifting
     * the indice instead of multiplying ... WHY??? I don't think it is faster,
     * but much less readable */
    mBoxXLog2  = 0; uint32_t dummy = mBoxX; while ( dummy >>= 1 ) ++mBoxXLog2;
    mBoxXYLog2 = 0; dummy = mBoxX*mBoxY;    while ( dummy >>= 1 ) ++mBoxXYLog2;
    if ( mBoxX != ( 1u << mBoxXLog2 ) || mBoxX * boxY != ( 1u << mBoxXYLog2 ) )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::setLatticeSize" << "] "
            << "Could not determine value for bit shift. "
            << "Check whether the box size is a power of 2! ( "
            << "boxX=" << mBoxX << " =? 2^" << mBoxXLog2 << " = " << ( 1 << mBoxXLog2 )
            << ", boxX*boY=" << mBoxX * mBoxY << " =? 2^" << mBoxXYLog2
            << " = " << ( 1 << mBoxXYLog2 ) << " )\n";
        throw std::runtime_error( msg.str() );
    }

    if ( mLattice != NULL )
        delete[] mLattice;
    mLattice = new uint8_t[ mBoxX * mBoxY * mBoxZ ];
    std::memset( (void *) mLattice, 0, mBoxX * mBoxY * mBoxZ * sizeof( *mLattice ) );
}

void UpdaterGPUScBFM_AB_Type::populateLattice()
{
    std::memset( mLattice, 0, mBoxX * mBoxY * mBoxZ * sizeof( *mLattice ) );
    for ( size_t i = 0; i < nAllMonomers; ++i )
    {
        mLattice[ linearizeBoxVectorIndex( mPolymerSystem[ 4*i+0 ],
                                           mPolymerSystem[ 4*i+1 ],
                                           mPolymerSystem[ 4*i+2 ] ) ] = 1;
    }
}

/**
 * Checks for excluded volume condition and for correctness of all monomer bonds
 * Beware, it useses and thereby thrashes mLattice. Might be cleaner to declare
 * as const and malloc and free some temporary buffer, but the time ...
 * https://randomascii.wordpress.com/2014/12/10/hidden-costs-of-memory-allocation/
 * "In my tests, for sizes ranging from 8 MB to 32 MB, the cost for a new[]/delete[] pair averaged about 7.5 μs (microseconds), split into ~5.0 μs for the allocation and ~2.5 μs for the free."
 *  => ~40k cycles
 */
void UpdaterGPUScBFM_AB_Type::checkSystem()
{
    if ( ! mLog.isActive( "Check" ) )
        return;

    if ( mLattice == NULL )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::checkSystem" << "] "
            << "mLattice is not allocated. You need to call "
            << "setNrOfAllMonomers and initialize before calling checkSystem!\n";
        mLog( "Error" ) << msg.str();
        throw std::invalid_argument( msg.str() );
    }

    /**
     * Test for excluded volume by setting all lattice points and count the
     * toal lattice points occupied. If we have overlap this will be smaller
     * than calculated for zero overlap!
     * mPolymerSystem only stores the lower left front corner of the 2x2x2
     * monomer cube. Use that information to set all 8 cells in the lattice
     * to 'occupied'
     */
    /*
     Lattice is an array of size Box_X*Box_Y*Box_Z. PolymerSystem holds the monomer positions which I strongly guess are supposed to be in the range 0<=x<Box_X. If I see correctly, then this part checks for excluded volume by occupying a 2x2x2 cube for each monomer in Lattice and then counting the total occupied cells and compare it to the theoretical value of nMonomers * 8. But Lattice seems to be too small for that kinda usage! I.e. for two particles, one being at x=0 and the other being at x=Box_X-1 this test should return that the excluded volume condition is not met! Therefore the effective box size is actually (Box_X-1,Box_X-1,Box_Z-1) which in my opinion should be a bug ??? */
    std::memset( mLattice, 0, mBoxX * mBoxY * mBoxZ * sizeof( *mLattice ) );
    for ( uint32_t i = 0; i < nAllMonomers; ++i )
    {
        int32_t const & x = mPolymerSystem[ 4*i   ];
        int32_t const & y = mPolymerSystem[ 4*i+1 ];
        int32_t const & z = mPolymerSystem[ 4*i+2 ];
        /**
         * @verbatim
         *           ...+---+---+
         *     ...'''   | 6 | 7 |
         *    +---+---+ +---+---+    y
         *    | 2 | 3 | | 4 | 5 |    ^ z
         *    +---+---+ +---+---+    |/
         *    | 0 | 1 |   ...'''     +--> x
         *    +---+---+'''
         * @endverbatim
         */
        mLattice[ linearizeBoxVectorIndex( x  , y  , z   ) ] = 1; /* 0 */
        mLattice[ linearizeBoxVectorIndex( x+1, y  , z   ) ] = 1; /* 1 */
        mLattice[ linearizeBoxVectorIndex( x  , y+1, z   ) ] = 1; /* 2 */
        mLattice[ linearizeBoxVectorIndex( x+1, y+1, z   ) ] = 1; /* 3 */
        mLattice[ linearizeBoxVectorIndex( x  , y  , z+1 ) ] = 1; /* 4 */
        mLattice[ linearizeBoxVectorIndex( x+1, y  , z+1 ) ] = 1; /* 5 */
        mLattice[ linearizeBoxVectorIndex( x  , y+1, z+1 ) ] = 1; /* 6 */
        mLattice[ linearizeBoxVectorIndex( x+1, y+1, z+1 ) ] = 1; /* 7 */
    }
    /* check total occupied cells inside lattice to ensure that the above
     * transfer went without problems. Note that the number will be smaller
     * if some monomers overlap!
     * Could also simply reduce mLattice with +, I think, because it only
     * cotains 0 or 1 ??? */
    unsigned nOccupied = 0;
    for ( unsigned i = 0u; i < mBoxX * mBoxY * mBoxZ; ++i )
        nOccupied += mLattice[i] != 0;
    if ( ! ( nOccupied == nAllMonomers * 8 ) )
    {
        std::stringstream msg;
        msg << "[" << __FILENAME__ << "::~checkSystem" << "] "
            << "Occupation count in mLattice is wrong! Expected 8*nMonomers="
            << 8 * nAllMonomers << " occupied cells, but got " << nOccupied;
        throw std::runtime_error( msg.str() );
    }

    /**
     * Check bonds i.e. that |dx|<=3 and whether it is allowed by the given
     * bond set
     */
    for ( unsigned i = 0; i < nAllMonomers; ++i )
    for ( unsigned iNeighbor = 0; iNeighbor < mNeighbors[i].size; ++iNeighbor )
    {
        /* calculate the bond vector between the neighbor and this particle
         * neighbor - particle = ( dx, dy, dz ) */
        intCUDA * const neighbor = & mPolymerSystem[ 4*mNeighbors[i].neighborIds[ iNeighbor ] ];
        int32_t const dx = neighbor[0] - mPolymerSystem[ 4*i+0 ];
        int32_t const dy = neighbor[1] - mPolymerSystem[ 4*i+1 ];
        int32_t const dz = neighbor[2] - mPolymerSystem[ 4*i+2 ];

        int erroneousAxis = -1;
        if ( ! ( -3 <= dx && dx <= 3 ) ) erroneousAxis = 0;
        if ( ! ( -3 <= dy && dy <= 3 ) ) erroneousAxis = 1;
        if ( ! ( -3 <= dz && dz <= 3 ) ) erroneousAxis = 2;
        if ( erroneousAxis >= 0 || mForbiddenBonds[ linearizeBondVectorIndex( dx, dy, dz ) ] )
        {
            std::stringstream msg;
            msg << "[" << __FILENAME__ << "::checkSystem] ";
            if ( erroneousAxis > 0 )
                msg << "Invalid " << 'X' + erroneousAxis << "Bond: ";
            if ( mForbiddenBonds[ linearizeBondVectorIndex( dx, dy, dz ) ] )
                msg << "This particular bond is forbidden: ";
            msg << "(" << dx << "," << dy<< "," << dz << ") between monomer "
                << i+1 << " at (" << mPolymerSystem[ 4*i+0 ] << ","
                                  << mPolymerSystem[ 4*i+1 ] << ","
                                  << mPolymerSystem[ 4*i+2 ] << ") and monomer "
                << mNeighbors[i].neighborIds[ iNeighbor ]+1 << " at ("
                << neighbor[0] << "," << neighbor[1] << "," << neighbor[2] << ")"
                << std::endl;
             throw std::runtime_error( msg.str() );
        }
    }
}

void UpdaterGPUScBFM_AB_Type::runSimulationOnGPU
(
    int32_t const nMonteCarloSteps
)
{
    std::clock_t const t0 = std::clock();

    long int const nThreads = 256;
    std::vector< long int > nBlocksForGroup( mnElementsInGroup.size() );
    for ( size_t i = 0u; i < nBlocksForGroup.size(); ++i )
        nBlocksForGroup[i] = ceilDiv( mnElementsInGroup[i], nThreads );

    /**
     * Statistics (min, max, mean, stddev) on filtering. Filtered because of:
     *   0: bonds, 1: volume exclusion, 2: volume exclusion (parallel)
     * These statistics are done for each group separately
     */
    std::vector< std::vector< double > > sums, sums2, mins, maxs, ns;
    std::vector< unsigned long long int > vFiltered;
    unsigned long long int * dpFiltered = NULL;
    auto constexpr nFilters = 5;
    if ( mLog.isActive( "Stats" ) )
    {
        auto const nGroups = mnElementsInGroup.size();
        sums .resize( nGroups, std::vector< double >( nFilters, 0            ) );
        sums2.resize( nGroups, std::vector< double >( nFilters, 0            ) );
        mins .resize( nGroups, std::vector< double >( nFilters, nAllMonomers ) );
        maxs .resize( nGroups, std::vector< double >( nFilters, 0            ) );
        ns   .resize( nGroups, std::vector< double >( nFilters, 0            ) );
        /* ns needed because we need to know how often each group was advanced */
        vFiltered.resize( nFilters );
        CUDA_ERROR( cudaMalloc( &dpFiltered, nFilters * sizeof( *dpFiltered ) ) );
        CUDA_ERROR( cudaMemsetAsync( (void*) dpFiltered, 0, nFilters * sizeof( *dpFiltered ), mStream ) );
    }

    cudaEvent_t tGpu0, tGpu1;
    if ( mLog.isActive( "Benchmark" ) )
    {
        cudaEventCreate( &tGpu0 );
        cudaEventCreate( &tGpu1 );
        cudaEventRecord( tGpu0 );
    }

    /* run simulation */
    for ( int32_t iStep = 1; iStep <= nMonteCarloSteps; ++iStep )
    {
        /* one Monte-Carlo step:
         *  - tries to move on average all particles one time
         *  - each particle could be touched, not just one group */
        for ( uint32_t iSubStep = 0; iSubStep < mnElementsInGroup.size(); ++iSubStep )
        {
            /* randomly choose which monomer group to advance */
            auto const iSpecies = randomNumbers.r250_rand32() % mnElementsInGroup.size();
            auto const seed     = randomNumbers.r250_rand32();
            auto const nBlocks  = nBlocksForGroup.at( iSpecies );

            /*
            if ( iStep < 3 )
                mLog( "Info" ) << "Calling Check-Kernel for species " << iSpecies << " for uint32_t * " << (void*) mNeighborsSorted->gpu << " + " << mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ) << " = " << (void*)( mNeighborsSorted->gpu + mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ) ) << " with pitch " << mNeighborsSortedInfo.getMatrixPitchElements( iSpecies ) << "\n";
            */

            kernelSimulationScBFMCheckSpecies
            <<< nBlocks, nThreads, 0, mStream >>>(
                mPolymerSystemSorted->gpu,
                mPolymerFlags->gpu,
                iSubGroupOffset[ iSpecies ],
                mLatticeTmp->gpu,
                mNeighborsSorted->gpu + mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ),
                mNeighborsSortedInfo.getMatrixPitchElements( iSpecies ),
                mnElementsInGroup[ iSpecies ], seed,
                mLatticeOut->texture
            );

            if ( mLog.isActive( "Stats" ) )
            {
                kernelCountFilteredCheck
                <<< nBlocks, nThreads, 0, mStream >>>(
                    mPolymerSystemSorted->gpu,
                    mPolymerFlags->gpu,
                    iSubGroupOffset[ iSpecies ],
                    mLatticeTmp->gpu,
                    mNeighborsSorted->gpu + mNeighborsSortedInfo.getMatrixOffsetElements( iSpecies ),
                    mNeighborsSortedInfo.getMatrixPitchElements( iSpecies ),
                    mnElementsInGroup[ iSpecies ], seed,
                    mLatticeOut->texture,
                    dpFiltered
                );
            }

            kernelSimulationScBFMPerformSpecies
            <<< nBlocks, nThreads, 0, mStream >>>(
                mPolymerSystemSorted->gpu + 4*iSubGroupOffset[ iSpecies ],
                mPolymerFlags->gpu + iSubGroupOffset[ iSpecies ],
                mLatticeOut->gpu,
                mnElementsInGroup[ iSpecies ],
                mLatticeTmp->texture
            );

            if ( mLog.isActive( "Stats" ) )
            {
                kernelCountFilteredPerform
                <<< nBlocks, nThreads, 0, mStream >>>(
                    mPolymerSystemSorted->gpu + 4*iSubGroupOffset[ iSpecies ],
                    mPolymerFlags->gpu + iSubGroupOffset[ iSpecies ],
                    mLatticeOut->gpu,
                    mnElementsInGroup[ iSpecies ],
                    mLatticeTmp->texture,
                    dpFiltered
                );
            }

            kernelSimulationScBFMZeroArraySpecies
            <<< nBlocks, nThreads, 0, mStream >>>(
                mPolymerSystemSorted->gpu + 4*iSubGroupOffset[ iSpecies ],
                mPolymerFlags->gpu + iSubGroupOffset[ iSpecies ],
                mLatticeTmp->gpu,
                mnElementsInGroup[ iSpecies ]
            );

            if ( mLog.isActive( "Stats" ) )
            {
                CUDA_ERROR( cudaMemcpyAsync( (void*) &vFiltered.at(0), (void*) dpFiltered,
                    nFilters * sizeof( *dpFiltered ), cudaMemcpyDeviceToHost, mStream ) );
                CUDA_ERROR( cudaStreamSynchronize( mStream ) );
                CUDA_ERROR( cudaMemsetAsync( (void*) dpFiltered, 0, nFilters * sizeof( *dpFiltered ), mStream ) );

                for ( auto iFilter = 0u; iFilter < nFilters; ++iFilter )
                {
                    double const x = vFiltered.at( iFilter );
                    sums .at( iSpecies ).at( iFilter ) += x;
                    sums2.at( iSpecies ).at( iFilter ) += x*x;
                    mins .at( iSpecies ).at( iFilter ) = std::min( mins.at( iSpecies ).at( iFilter ), x );
                    maxs .at( iSpecies ).at( iFilter ) = std::max( maxs.at( iSpecies ).at( iFilter ), x );
                    ns   .at( iSpecies ).at( iFilter ) += 1;
                }
            }
        }
    }

    if ( mLog.isActive( "Benchmark" ) )
    {
        // https://devblogs.nvidia.com/how-implement-performance-metrics-cuda-cc/#disqus_thread
        cudaEventRecord( tGpu1 );
        cudaEventSynchronize( tGpu1 );  // basically a StreamSynchronize
        float milliseconds = 0;
        cudaEventElapsedTime( & milliseconds, tGpu0, tGpu1 );
        mLog( "Benchmark" ) << "tGpuLoop = " << milliseconds / 1000. << "s\n";
    }

    if ( mLog.isActive( "Stats" ) && dpFiltered != NULL )
    {
        CUDA_ERROR( cudaFree( dpFiltered ) );
        mLog( "Stats" ) << "Filter analysis. Format:\n" << "Filter Reason: min | mean +- stddev | max\n";
        std::map< int, std::string > filterNames;
        filterNames[0] = "Box Boundaries";
        filterNames[1] = "Invalid Bonds";
        filterNames[2] = "Volume Exclusion";
        filterNames[3] = "! Invalid Bonds && Volume Exclusion";
        filterNames[4] = "! Invalid Bonds && ! Volume Exclusion && Parallel Volume Exclusion";
        for ( auto iGroup = 0u; iGroup < mnElementsInGroup.size(); ++iGroup )
        {
            mLog( "Stats" ) << "\n=== Group " << char( 'A' + iGroup ) << " (" << mnElementsInGroup[ iGroup ] << ") ===\n";
            for ( auto iFilter = 0u; iFilter < nFilters; ++iFilter )
            {
                double const nRepeats = ns.at( iGroup ).at( iFilter );
                double const mean = sums .at( iGroup ).at( iFilter ) / nRepeats;
                double const sum2 = sums2.at( iGroup ).at( iFilter ) / nRepeats;
                auto const stddev = std::sqrt( nRepeats/(nRepeats-1) * ( sum2 - mean * mean ) );
                auto const & min = mins.at( iGroup ).at( iFilter );
                auto const & max = maxs.at( iGroup ).at( iFilter );
                mLog( "Stats" )
                    << filterNames[iFilter] << ": "
                    << min  << "(" << 100. * min  / mnElementsInGroup[ iGroup ] << "%) | "
                    << mean << "(" << 100. * mean / mnElementsInGroup[ iGroup ] << "%) +- "
                    << stddev << " | "
                    << max  << "(" << 100. * max  / mnElementsInGroup[ iGroup ] << "%)\n";
            }
            if ( sums.at( iGroup ).at(0) != 0 )
                mLog( "Stats" ) << "The value for remeaining particles after first kernel will be wrong if we have non-periodic boundary conditions (todo)!\n";
            auto const nAvgFilteredKernel1 = ( sums.at( iGroup ).at(1) + sums.at( iGroup ).at(3) ) / ns.at( iGroup ).at(3);
            mLog( "Stats" ) << "Remaining after 1st kernel: " << mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 << "(" << 100. * ( mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 ) / mnElementsInGroup[ iGroup ] << "%)\n";
            auto const nAvgFilteredKernel2 = sums.at( iGroup ).at(4) / ns.at( iGroup ).at(4);
            auto const percentageMoved = ( mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 - nAvgFilteredKernel2 ) / mnElementsInGroup[ iGroup ];
            mLog( "Stats" ) << "For parallel collisions it's interesting to give the percentage of sorted particles in relation to whose who can actually still move, not in relation to ALL particles\n"
                << "    Third kernel gets " << mnElementsInGroup[ iGroup ] << " monomers, but first kernel (bonds, box, volume exclusion) already filtered " << nAvgFilteredKernel1 << "(" << 100. * nAvgFilteredKernel1 / mnElementsInGroup[ iGroup ] << "%) which the 2nd kernel has to refilter again (if no stream compaction is used).\n"
                << "    Then from the remaining " << mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 << "(" << 100. * ( mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 ) / mnElementsInGroup[ iGroup ] << "%) the 2nd kernel filters out another " << nAvgFilteredKernel2 << " particles which in relation to the particles which actually still could move before is: " << 100. * nAvgFilteredKernel2 / ( mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 ) << "% and in relation to the total particles: " << 100. * nAvgFilteredKernel2 / mnElementsInGroup[ iGroup ] << "%\n"
                << "    Therefore in total (all three kernels) and on average (multiple salves of three kernels) " << ( mnElementsInGroup[ iGroup ] - nAvgFilteredKernel1 - nAvgFilteredKernel2 ) << "(" << 100. * percentageMoved << "%) particles can be moved per step. I.e. it takes on average " << 1. / percentageMoved << " Monte-Carlo steps per monomer until a monomer actually changes position.\n";
        }
    }

    mtCopyBack0 = std::chrono::high_resolution_clock::now();

    /* all MCS are done- copy information back from GPU to host */
    if ( mLog.isActive( "Check" ) )
    {
        mLatticeTmp->pop( false ); // sync
        size_t nOccupied = 0;
        for ( size_t i = 0u; i < mBoxX * mBoxY * mBoxZ; ++i )
            nOccupied += mLatticeTmp->host[i] != 0;
        if ( nOccupied != 0 )
        {
            std::stringstream msg;
            msg << "latticeTmp occupation (" << nOccupied << ") should be 0! Exiting ...\n";
            throw std::runtime_error( msg.str() );
        }
    }

    /* copy into mPolymerSystem and drop the property tag while doing so.
     * would be easier and probably more efficient if mPolymerSystem->gpu/host
     * would be a struct of arrays instead of an array of structs !!! */
    mPolymerSystemSorted->pop( false ); // sync

    if ( mLog.isActive( "Benchmark" ) )
    {
        std::clock_t const t1 = std::clock();
        double const dt = float(t1-t0) / CLOCKS_PER_SEC;
        mLog( "Benchmark" )
        << "run time (GPU): " << nMonteCarloSteps << "\n"
        << "mcs = " << nMonteCarloSteps  << "  speed [performed monomer try and move/s] = MCS*N/t: "
        << nMonteCarloSteps * ( nAllMonomers / dt )  << "     runtime[s]:" << dt << "\n";
    }

    /* untangle reordered array so that LeMonADE can use it again */
    for ( size_t i = 0u; i < nAllMonomers; ++i )
    {
        auto const pTarget = mPolymerSystemSorted->host + 4*iToiNew[i];
        if ( i < 10 )
            mLog( "Info" ) << "Copying back " << i << " from " << iToiNew[i] << "\n";
        mPolymerSystem[ 4*i+0 ] = pTarget[0];
        mPolymerSystem[ 4*i+1 ] = pTarget[1];
        mPolymerSystem[ 4*i+2 ] = pTarget[2];
        mPolymerSystem[ 4*i+3 ] = pTarget[3];
    }

    checkSystem(); // no-op if "Check"-level deactivated
}

/**
 * GPUScBFM_AB_Type::initialize and run and cleanup should be usable on
 * repeat. Which means we need to destruct everything created in
 * GPUScBFM_AB_Type::initialize, which encompasses setLatticeSize,
 * setNrOfAllMonomers and initialize. Currently this includes all allocs,
 * so we can simply call destruct.
 */
void UpdaterGPUScBFM_AB_Type::cleanup()
{
    /* check whether connectivities on GPU got corrupted */
    for ( uint32_t i = 0; i < nAllMonomers; ++i )
    {
        unsigned const nNeighbors = ( mPolymerSystem[ 4*i+3 ] & 224 /* 0b11100000 */ ) >> 5;
        if ( nNeighbors != mNeighbors[i].size )
        {
            std::stringstream msg;
            msg << "[" << __FILENAME__ << "::~cleanup" << "] "
                << "Connectivities in property field of mPolymerSystem are "
                << "different from host-side connectivities. This should not "
                << "happen! (Monomer " << i << ": " << nNeighbors << " != "
                << mNeighbors[i].size << "\n";
            throw std::runtime_error( msg.str() );
        }
    }
    this->destruct();
}
