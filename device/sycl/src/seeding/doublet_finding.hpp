/** TRACCC library, part of the ACTS project (R&D line)
 *
 * (c) 2021-2022 CERN for the benefit of the ACTS project
 *
 * Mozilla Public License Version 2.0
 */
#pragma once

// SYCL library include(s).
#include "doublet_counter.hpp"
#include "traccc/sycl/utils/queue_wrapper.hpp"

// Project include(s).
#include "traccc/seeding/detail/doublet.hpp"
#include "traccc/seeding/detail/seeding_config.hpp"
#include "traccc/seeding/detail/spacepoint_grid.hpp"

// VecMem include(s).
#include <vecmem/memory/memory_resource.hpp>

namespace traccc::sycl {

/// Forward declaration of doublet finding function
/// The mid-bot and mid-top doublets are found for the compatible middle
/// spacepoints which was recorded by doublet_counting
///
/// @param config seed finder config
/// @param internal_sp_container vecmem container for internal spacepoint
/// @param doublet_counter_container vecmem container for doublet_counter
/// @param mid_bot_doublet_container vecmem container for mid-bot doublets
/// @param mid_top_doublet_container vecmem container for mid-top doublets
/// @param resource vecmem memory resource
/// @param q sycl queue for kernel scheduling
void doublet_finding(const seedfinder_config& config, sp_grid& internal_sp,
                     host_doublet_counter_container& doublet_counter_container,
                     host_doublet_container& mid_bot_doublet_container,
                     host_doublet_container& mid_top_doublet_container,
                     vecmem::memory_resource& resource, queue_wrapper queue);

}  // namespace traccc::sycl
