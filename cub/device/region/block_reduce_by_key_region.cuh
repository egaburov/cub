/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::BlockReduceByKeyRegion implements a stateful abstraction of CUDA thread blocks for participating in device-wide reduce-value-by-key.
 */

#pragma once

#include <iterator>

#include "device_scan_types.cuh"
#include "../../block/block_load.cuh"
#include "../../block/block_store.cuh"
#include "../../block/block_scan.cuh"
#include "../../block/block_exchange.cuh"
#include "../../block/block_discontinuity.cuh"
#include "../../grid/grid_queue.cuh"
#include "../../iterator/cache_modified_input_iterator.cuh"
#include "../../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Tuning policy types
 ******************************************************************************/

/**
 * Parameterizable tuning policy type for BlockReduceByKeyRegion
 */
template <
    int                         _BLOCK_THREADS,                 ///< Threads per thread block
    int                         _ITEMS_PER_THREAD,              ///< Items per thread (per tile of input)
    BlockLoadAlgorithm          _LOAD_ALGORITHM,                ///< The BlockLoad algorithm to use
    CacheLoadModifier           _LOAD_MODIFIER,                 ///< Cache load modifier for reading input elements
    bool                        _TWO_PHASE_SCATTER,             ///< Whether or not to coalesce output values in shared memory before scattering them to global
    BlockScanAlgorithm          _SCAN_ALGORITHM>                ///< The BlockScan algorithm to use
struct BlockReduceByKeyRegionPolicy
{
    enum
    {
        BLOCK_THREADS           = _BLOCK_THREADS,               ///< Threads per thread block
        ITEMS_PER_THREAD        = _ITEMS_PER_THREAD,            ///< Items per thread (per tile of input)
        TWO_PHASE_SCATTER       = _TWO_PHASE_SCATTER,           ///< Whether or not to coalesce output values in shared memory before scattering them to global
    };

    static const BlockLoadAlgorithm     LOAD_ALGORITHM          = _LOAD_ALGORITHM;      ///< The BlockLoad algorithm to use
    static const CacheLoadModifier      LOAD_MODIFIER           = _LOAD_MODIFIER;       ///< Cache load modifier for reading input elements
    static const BlockScanAlgorithm     SCAN_ALGORITHM          = _SCAN_ALGORITHM;      ///< The BlockScan algorithm to use
};




/******************************************************************************
 * Thread block abstractions
 ******************************************************************************/

/**
 * \brief BlockReduceByKeyRegion implements a stateful abstraction of CUDA thread blocks for participating in device-wide reduce-value-by-key across a region of tiles
 */
template <
    typename    BlockReduceByKeyRegionPolicy,   ///< Parameterized BlockReduceByKeyRegionPolicy tuning policy type
    typename    KeyInputIterator,               ///< Random-access input iterator type for keys
    typename    KeyOutputIterator,              ///< Random-access output iterator type for keys
    typename    ValueInputIterator,             ///< Random-access input iterator type for values
    typename    ValueOutputIterator,            ///< Random-access output iterator type for values
    typename    EqualityOp,                     ///< Key equality operator type
    typename    ReductionOp,                    ///< Value reduction operator type
    typename    Offset>                         ///< Signed integer type for global offsets
struct BlockReduceByKeyRegion
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    // Data type of key iterator
    typedef typename std::iterator_traits<KeyInputIterator>::value_type Key;

    // Data type of value iterator
    typedef typename std::iterator_traits<ValueInputIterator>::value_type Value;

    // Constants
    enum
    {
        BLOCK_THREADS       = BlockReduceByKeyRegionPolicy::BLOCK_THREADS,
        ITEMS_PER_THREAD    = BlockReduceByKeyRegionPolicy::ITEMS_PER_THREAD,
        TWO_PHASE_SCATTER   = (BlockReduceByKeyRegionPolicy::TWO_PHASE_SCATTER) && (ITEMS_PER_THREAD > 1),
        TILE_ITEMS          = BLOCK_THREADS * ITEMS_PER_THREAD,

        // Whether or not the scan operation has a known identity value (true if we're performing addition on a primitive type)
        HAS_IDENTITY        = (Equals<ReductionOp, cub::Sum>::VALUE) && (Traits<Value>::PRIMITIVE),
    };

    // Cache-modified input iterator wrapper type for keys
    typedef typename If<IsPointer<KeyInputIterator>::VALUE,
            CacheModifiedInputIterator<BlockReduceByKeyRegionPolicy::LOAD_MODIFIER, Key, Offset>,   // Wrap the native input pointer with CacheModifiedValueInputIterator
            KeyInputIterator>::Type                                                                 // Directly use the supplied input iterator type
        WrappedKeyInputIterator;

    // Cache-modified input iterator wrapper type for values
    typedef typename If<IsPointer<ValueInputIterator>::VALUE,
            CacheModifiedInputIterator<BlockReduceByKeyRegionPolicy::LOAD_MODIFIER, Value, Offset>,  // Wrap the native input pointer with CacheModifiedValueInputIterator
            ValueInputIterator>::Type                                                                // Directly use the supplied input iterator type
        WrappedValueInputIterator;

    // Key-value tuple type
    typedef KeyValuePair<Key, Value> KeyValuePair;

    // Value-offset tuple type for scanning (maps accumulated values to segment index)
    typedef ItemOffsetPair<Value, Offset> ValueOffsetPair;

    // Reduce-value-by-segment scan operator
    struct ReduceByKeyOp
    {
        ReductionOp op;                 ///< Wrapped reduction operator

        /// Constructor
        __device__ __forceinline__ ReduceByKeyOp(ReductionOp op) : op(op) {}

        /// Scan operator
        __device__ __forceinline__ ValueOffsetPair operator()(
            const ValueOffsetPair &first,       ///< First partial reduction
            const ValueOffsetPair &second)      ///< Second partial reduction
        {
            ValueOffsetPair retval;
            retval.offset = first.offset + second.offset;

            if (second.offset)
            {
                retval.value = second.value;
                return retval;
            }
            else
            {
                retval.value = op(first.value, second.value);
                return retval;
            }

/*
            ValueOffsetPair retval;
            retval.offset = first.offset + second.offset;   // Accumulate number of segment resets from each into the running aggregate
            retval.value = (second.offset) ?
                    second.value :                          // The second partial reduction spans a segment reset, so it's value aggregate becomes the running aggregate
                    op(first.value, second.value);          // The second partial reduction does not span a reset, so accumulate both into the running aggregate

            return retval;
*/
        }
    };

    // Parameterized BlockLoad type for keys
    typedef BlockLoad<
            WrappedKeyInputIterator,
            BlockReduceByKeyRegionPolicy::BLOCK_THREADS,
            BlockReduceByKeyRegionPolicy::ITEMS_PER_THREAD,
            BlockReduceByKeyRegionPolicy::LOAD_ALGORITHM>
        BlockLoadKeys;

    // Parameterized BlockLoad type for values
    typedef BlockLoad<
            WrappedValueInputIterator,
            BlockReduceByKeyRegionPolicy::BLOCK_THREADS,
            BlockReduceByKeyRegionPolicy::ITEMS_PER_THREAD,
            BlockReduceByKeyRegionPolicy::LOAD_ALGORITHM>
        BlockLoadValues;

    // Parameterized BlockExchange type for locally compacting items as part of a two-phase scatter
    typedef BlockExchange<
            KeyValuePair,
            BLOCK_THREADS,
            ITEMS_PER_THREAD>
        BlockExchangeT;

    // Parameterized BlockDiscontinuity type for keys
    typedef BlockDiscontinuity<Key, BLOCK_THREADS> BlockDiscontinuityKeys;

    // Tile status descriptor type
    typedef LookbackTileDescriptor<ValueOffsetPair> TileDescriptor;

    // Parameterized BlockScan type
    typedef BlockScan<
            ValueOffsetPair,
            BlockReduceByKeyRegionPolicy::BLOCK_THREADS,
            BlockReduceByKeyRegionPolicy::SCAN_ALGORITHM>
        BlockScanAllocations;

    // Callback type for obtaining tile prefix during block scan
    typedef LookbackBlockPrefixCallbackOp<
            ValueOffsetPair,
            ReduceByKeyOp>
        LookbackPrefixCallbackOp;

    // Shared memory type for this threadblock
    struct _TempStorage
    {
        typename LookbackPrefixCallbackOp::TempStorage  prefix;         // Smem needed for cooperative prefix callback
        typename BlockScanAllocations::TempStorage      scan;           // Smem needed for tile scanning
        typename BlockDiscontinuityKeys::TempStorage    discontinuity;  // Smem needed for discontinuity detection

        union
        {
            // Smem needed for loading keys
            typename BlockLoadKeys::TempStorage load_keys;

            // Smem needed for loading values
            typename BlockLoadValues::TempStorage load_values;

            // Smem needed for two-phase scatter (NullType if not needed)
//                    typename If<TWO_PHASE_SCATTER, typename BlockExchangeT::TempStorage, NullType>::Type exchange;
        };

        Offset      tile_idx;               // Shared tile index
        Offset      tile_num_flags_prefix;  // Exclusive tile prefix
    };

    // Alias wrapper allowing storage to be unioned
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Per-thread fields
    //---------------------------------------------------------------------

    _TempStorage                    &temp_storage;      ///< Reference to temp_storage

    WrappedKeyInputIterator         d_keys_in;          ///< Input keys
    KeyOutputIterator               d_keys_out;         ///< Output keys

    WrappedValueInputIterator       d_values_in;        ///< Input values
    ValueOutputIterator             d_values_out;       ///< Output values

    InequalityWrapper<EqualityOp>   inequality_op;      ///< Key inequality operator
    ReduceByKeyOp                   scan_op;            ///< Reduce-value-by flag scan operator
    Offset                          num_items;          ///< Total number of input items


    //---------------------------------------------------------------------
    // Constructor
    //---------------------------------------------------------------------

    // Constructor
    __device__ __forceinline__
    BlockReduceByKeyRegion(
        TempStorage                 &temp_storage,      ///< Reference to temp_storage
        KeyInputIterator            d_keys_in,          ///< Input keys
        KeyOutputIterator           d_keys_out,         ///< Output keys
        ValueInputIterator          d_values_in,        ///< Input values
        ValueOutputIterator         d_values_out,       ///< Output values
        EqualityOp                  equality_op,        ///< Key equality operator
        ReductionOp                 reduction_op,       ///< Value reduction operator
        Offset                      num_items)          ///< Total number of input items
    :
        temp_storage(temp_storage.Alias()),
        d_keys_in(d_keys_in),
        d_keys_out(d_keys_out),
        d_values_in(d_values_in),
        d_values_out(d_values_out),
        inequality_op(equality_op),
        scan_op(reduction_op),
        num_items(num_items)
    {}


    //---------------------------------------------------------------------
    // Block scan utility methods
    //---------------------------------------------------------------------

    /**
     * Scan with identity (first tile)
     */
    __device__ __forceinline__
    void ScanBlock(
        ValueOffsetPair     (&values_and_segments)[ITEMS_PER_THREAD],
        ValueOffsetPair     &block_aggregate,
        Int2Type<true>      has_identity)
    {
        ValueOffsetPair identity;
        identity.value = 0;
        identity.offset = 0;
        BlockScanAllocations(temp_storage.scan).ExclusiveScan(values_and_segments, values_and_segments, identity, scan_op, block_aggregate);
    }

    /**
     * Scan without identity (first tile).  Without an identity, the first output item is undefined.
     *
     */
    __device__ __forceinline__
    void ScanBlock(
        ValueOffsetPair     (&values_and_segments)[ITEMS_PER_THREAD],
        ValueOffsetPair     &block_aggregate,
        Int2Type<false>     has_identity)
    {
        BlockScanAllocations(temp_storage.scan).ExclusiveScan(values_and_segments, values_and_segments, scan_op, block_aggregate);
    }

    /**
     * Scan with identity (subsequent tile)
     */
    __device__ __forceinline__
    void ScanBlock(
        ValueOffsetPair             (&values_and_segments)[ITEMS_PER_THREAD],
        ValueOffsetPair             &block_aggregate,
        LookbackPrefixCallbackOp    &prefix_op,
        Int2Type<true>              has_identity)
    {
        ValueOffsetPair identity;
        identity.value = 0;
        identity.offset = 0;
        BlockScanAllocations(temp_storage.scan).ExclusiveScan(values_and_segments, values_and_segments, identity, scan_op, block_aggregate, prefix_op);
    }

    /**
     * Scan without identity (subsequent tile).  Without an identity, the first output item is undefined.
     */
    __device__ __forceinline__
    void ScanBlock(
        ValueOffsetPair             (&values_and_segments)[ITEMS_PER_THREAD],
        ValueOffsetPair             &block_aggregate,
        LookbackPrefixCallbackOp    &prefix_op,
        Int2Type<false>             has_identity)
    {
        BlockScanAllocations(temp_storage.scan).ExclusiveScan(values_and_segments, values_and_segments, scan_op, block_aggregate, prefix_op);
    }


    //---------------------------------------------------------------------
    // Zip utility methods
    //---------------------------------------------------------------------

    template <bool LAST_TILE>
    __device__ __forceinline__ void ZipValuesAndFlags(
        Offset          num_remaining,
        Value           (&values)[ITEMS_PER_THREAD],
        Offset          (&flags)[ITEMS_PER_THREAD],
        ValueOffsetPair (&values_and_segments)[ITEMS_PER_THREAD])
    {
        // Zip values and flags
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
        {
            // Unset flags for out-of-bounds keys
            if ((LAST_TILE) && (Offset(threadIdx.x * ITEMS_PER_THREAD) + ITEM >= num_remaining))
                flags[ITEM] = 0;

            values_and_segments[ITEM].value      = values[ITEM];
            values_and_segments[ITEM].offset     = flags[ITEM];
        }
    }

    //---------------------------------------------------------------------
    // Scatter utility methods
    //---------------------------------------------------------------------



    /**
     * Scatter flagged items to output offsets (specialized for direct scattering)
     *
     * The exclusive scan causes each head flag to be paired with the previous
     * value aggregate. As such:
     * - The scatter offsets must be decremented for value value aggregates
     * - The first tile does not scatter the first flagged value (it is undefined from the exclusive scan)
     * - If the tile is partially-full, we need to scatter the first out-of-bounds value (which aggregates all valid values in the last segment)
     *
     */
    template <
        bool LAST_TILE>
    __device__ __forceinline__ void ScatterDirect(
        int             tile_idx,
        Offset          num_remaining,
        Key             (&keys)[ITEMS_PER_THREAD],
        ValueOffsetPair (&values_and_segments)[ITEMS_PER_THREAD],
        Offset          (&flags)[ITEMS_PER_THREAD],
        Offset          tile_num_flags)
    {
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
        {
            // Scatter key
            if (flags[ITEM])
            {
                d_keys_out[values_and_segments[ITEM].offset] = keys[ITEM];
            }

            bool is_first_flag     = (tile_idx == 0) && (ITEM == 0) && (threadIdx.x == 0);
            bool is_oob_value      = (LAST_TILE) && (Offset(threadIdx.x * ITEMS_PER_THREAD) + ITEM == num_remaining);

            // Scatter value reduction
            if (((flags[ITEM] || is_oob_value)) && (!is_first_flag))
            {
                d_values_out[values_and_segments[ITEM].offset - 1] = values_and_segments[ITEM].value;
            }
        }
    }


    /**
     * Scatter flagged items to output offsets (specialized for two-phase scattering)
     *
     * The exclusive scan causes each head flag to be paired with the previous
     * value aggregate. As such:
     * - The scatter offsets must be decremented for value value aggregates
     * - The first tile does not scatter the first flagged value (it is undefined from the exclusive scan)
     * - If the tile is partially-full, we need to scatter the first out-of-bounds value (which aggregates all valid values in the last segment)
     *
     */
    template <
        bool FIRST_TILE,
        bool FULL_TILE>
    __device__ __forceinline__ void ScatterTwoPhase(
        Offset          num_remaining,
        Key             (&keys)[ITEMS_PER_THREAD],
        ValueOffsetPair (&values_and_segments)[ITEMS_PER_THREAD],
        Offset          (&flags)[ITEMS_PER_THREAD],
        Offset          tile_num_flags,
        Offset          tile_num_flags_prefix)
    {
/*
        int             local_ranks[ITEMS_PER_THREAD];      // Local scatter ranks
        KeyValuePair    key_value_pairs[ITEMS_PER_THREAD];  // Zipped keys and values

        // Convert global ranks into local ranks and zip items together.  (The first
        // pair in the first tile has an invalid value and the last pair in the last tile
        // has an invalid key)

        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
        {
            local_ranks[ITEM]               = values_and_segments[ITEM].offset - tile_num_flags_prefix;
            key_value_pairs[ITEM].key       = keys[ITEM];
            key_value_pairs[ITEM].value     = values_and_segments[ITEM].value;

            // Set flag on first out-of-bounds value
            if ((!FULL_TILE) && (Offset(threadIdx.x * ITEMS_PER_THREAD) + ITEM == num_remaining))
            {
                flags[ITEM] = 1;
            }
        }

        // Number to exchange
        Offset exchange_count = (FULL_TILE) ?
            tile_num_flags :
            tile_num_flags + 1;

        // Exchange zipped items to striped arrangement
        BlockExchangeT(temp_storage.exchange).ScatterToStriped(key_value_pairs, local_ranks, flags, exchange_count);

        // Store directly in striped order
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            Offset  compacted_offset    = (ITEM * BLOCK_THREADS) + threadIdx.x;
            bool    is_first_flag       = FIRST_TILE && (ITEM == 0) && (threadIdx.x == 0);

            // Scatter key
            if (compacted_offset < tile_num_flags)
                d_keys_out[tile_num_flags_prefix + compacted_offset] = key_value_pairs[ITEM].key;

            // Scatter value
            if ((compacted_offset < exchange_count) && (!is_first_flag))
            {
                d_values_out[tile_num_flags_prefix + compacted_offset - 1] = key_value_pairs[ITEM].value;
            }
        }
*/
    }



    //---------------------------------------------------------------------
    // Cooperatively scan a device-wide sequence of tiles with other CTAs
    //---------------------------------------------------------------------

    /**
     * Process a tile of input (dynamic domino scan)
     */
    template <
        bool                LAST_TILE>
    __device__ __forceinline__ ValueOffsetPair ConsumeTile(
        Offset              num_items,          ///< Total number of global input items
        Offset              num_remaining,      ///< Number of global input items remaining (including this tile)
        int                 tile_idx,           ///< Tile index
        Offset              block_offset,       ///< Tile offset
        TileDescriptor      *d_tile_status)     ///< Global list of tile status
    {
        Key                 keys[ITEMS_PER_THREAD];                         // Tile keys
        Key                 values[ITEMS_PER_THREAD];                       // Tile values
        Offset              flags[ITEMS_PER_THREAD];                        // Segment head flags
        ValueOffsetPair     values_and_segments[ITEMS_PER_THREAD];          // Zipped values and segment flags|indices

//        Offset              exclusive_segments;                             // Running count of segments (excluding this tile)
        ValueOffsetPair     running_total;                                  // Running count of segments and current value aggregate (including this tile)
        ValueOffsetPair     block_aggregate;                                // Count of segments and current value aggregate (only this tile)

        // Obtain the last key in the previous tile to compare with
        Key tile_predecessor_key;
        if ((tile_idx != 0) && (threadIdx.x == 0))
            tile_predecessor_key = d_keys_in[block_offset - 1];

        // Load keys and values
        if (LAST_TILE)
        {
            // Repeat last item for out-of-bounds keys and values
            BlockLoadKeys(temp_storage.load_keys).Load(d_keys_in + block_offset, keys, num_remaining);

            if (sizeof(Key) != sizeof(Value))
                __syncthreads();

            BlockLoadValues(temp_storage.load_values).Load(d_values_in + block_offset, values, num_remaining);
        }
        else
        {
            BlockLoadKeys(temp_storage.load_keys).Load(d_keys_in + block_offset, keys);

            if (sizeof(Key) != sizeof(Value))
                __syncthreads();

            BlockLoadValues(temp_storage.load_values).Load(d_values_in + block_offset, values);
        }

        if (tile_idx == 0)
        {
            // First tile

            // Set head flags.  First tile sets the first flag for the first item
            BlockDiscontinuityKeys(temp_storage.discontinuity).FlagHeads(flags, keys, inequality_op);

            // Zip values and flags
            ZipValuesAndFlags<LAST_TILE>(num_remaining, values, flags, values_and_segments);

            // Exclusive scan of values and flags
            ScanBlock(values_and_segments, block_aggregate, Int2Type<HAS_IDENTITY>());

            // Update tile status if this is not the last tile
            if (!LAST_TILE && (threadIdx.x == 0))
                TileDescriptor::SetPrefix(d_tile_status, block_aggregate);

            // Set offset for first scan output
            if (!HAS_IDENTITY && (threadIdx.x == 0))
                values_and_segments[0].offset = 0;

//            exclusive_segments  = 0;
            running_total = block_aggregate;
        }
        else
        {
            // Not first tile

            // Set head flags
            BlockDiscontinuityKeys(temp_storage.discontinuity).FlagHeads(flags, keys, inequality_op, tile_predecessor_key);

            // Zip values and flags
            ZipValuesAndFlags<LAST_TILE>(num_remaining, values, flags, values_and_segments);

            // Exclusive scan of values and flags
            LookbackPrefixCallbackOp prefix_op(d_tile_status, temp_storage.prefix, scan_op, tile_idx);
            ScanBlock(values_and_segments, block_aggregate, prefix_op, Int2Type<HAS_IDENTITY>());

//            exclusive_segments  = prefix_op.exclusive_prefix.offset;
            running_total = prefix_op.inclusive_prefix;

        }

        ScatterDirect<LAST_TILE>(
            tile_idx,
            num_remaining,
            keys,
            values_and_segments,
            flags,
            block_aggregate.offset);



/*
        // Do a one-phase scatter if (a) two-phase is disabled or (b) the average number of selected items per thread is less than one
        if ((!TWO_PHASE_SCATTER) || ((block_aggregate.offset >> Log2<BLOCK_THREADS>::VALUE) == 0))
        {
            ScatterDirect<FIRST_TILE, FULL_TILE>(
                num_remaining,
                keys,
                values_and_segments,
                flags,
                tile_num_flags);
        }
        else
        {
            // First thread shares the exclusive tile prefix
            if (threadIdx.x == 0)
            {
                temp_storage.tile_num_flags_prefix = tile_num_flags_prefix;
            }

            __syncthreads();

            // Load exclusive tile prefix in all threads
            Offset tile_num_flags_prefix = temp_storage.tile_num_flags_prefix;

            ScatterTwoPhase<FIRST_TILE, FULL_TILE>(
                num_remaining,
                keys,
                values_and_segments,
                flags,
                tile_num_flags,
                tile_num_flags_prefix);
        }
*/

        return running_total;
    }


    /**
     * Dequeue and scan tiles of items as part of a dynamic domino scan
     */
    template <typename NumSegmentsIterator>         ///< Output iterator type for recording number of items selected
    __device__ __forceinline__ void ConsumeRegion(
        int                     num_tiles,          ///< Total number of input tiles
        GridQueue<int>          queue,              ///< Queue descriptor for assigning tiles of work to thread blocks
        TileDescriptor          *d_tile_status,     ///< Global list of tile status
        NumSegmentsIterator     d_num_segments)     ///< Output pointer for total number of segments identified
    {
#if CUB_PTX_VERSION < 200

        // No concurrent kernels are allowed, and blocks are launched in increasing order, so just assign one tile per block (up to 65K blocks)

        int             tile_idx        = blockIdx.x;                       // Current tile index
        Offset          block_offset    = Offset(TILE_ITEMS) * tile_idx;    // Global offset for the current tile
        Offset          num_remaining   = num_items - block_offset;         // Remaining items (including this tile)

        if (num_remaining > TILE_ITEMS)
        {
            // Full tile
            ConsumeTile<false>(num_items, num_remaining, tile_idx, block_offset, d_tile_status);
        }
        else if (num_remaining > 0)
        {
            // Last tile
            Offset running_total = ConsumeTile<true>(num_items, num_remaining, tile_idx, block_offset, d_tile_status);

            // Output the total number of items selected
            if (threadIdx.x == 0)
            {
                *d_num_segments = running_total.offset;

                // If the last tile is a whole tile, the inclusive prefix contains accumulated value reduction for the last segment
                if (num_remaining == TILE_ITEMS)
                {
                    d_values_out[running_total.offset - 1] = running_total.value;
                }
            }
        }


#else

        // Work-steal tiles

        // Get tile index
        if (threadIdx.x == 0)
            temp_storage.tile_idx = queue.Drain(1);

        __syncthreads();

        int             tile_idx        = temp_storage.tile_idx;            // Current tile index
        Offset          block_offset    = Offset(TILE_ITEMS) * tile_idx;    // Global offset for the current tile
        Offset          num_remaining   = num_items - block_offset;         // Remaining items (including this tile)

        while (num_remaining > TILE_ITEMS)
        {
            // Consume full tile
            ConsumeTile<false>(num_items, num_remaining, tile_idx, block_offset, d_tile_status);

            // Get tile index
            if (threadIdx.x == 0)
                temp_storage.tile_idx = queue.Drain(1);

            __syncthreads();

            tile_idx        = temp_storage.tile_idx;
            block_offset    = Offset(TILE_ITEMS) * tile_idx;
            num_remaining   = num_items - block_offset;
        }

        if (num_remaining > 0)
        {
            // Consume last tile (treat as partially-full)
            ValueOffsetPair running_total = ConsumeTile<true>(num_items, num_remaining, tile_idx, block_offset, d_tile_status);

            if ((threadIdx.x == 0))
            {
                // Output the total number of items selected
                *d_num_segments = running_total.offset;

                // If the last tile is a whole tile, the inclusive prefix contains accumulated value reduction for the last segment
                if (num_remaining == TILE_ITEMS)
                {
                    d_values_out[running_total.offset - 1] = running_total.value;
                }
            }
        }

#endif

    }

};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)

