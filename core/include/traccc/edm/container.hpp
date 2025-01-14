/** TRACCC library, part of the ACTS project (R&D line)
 *
 * (c) 2021-2022 CERN for the benefit of the ACTS project
 *
 * Mozilla Public License Version 2.0
 */

#pragma once

// Project include(s).
#include "traccc/definitions/qualifiers.hpp"
#include "traccc/edm/details/device_container.hpp"
#include "traccc/edm/details/host_container.hpp"

// VecMem include(s).
#include <vecmem/containers/data/jagged_vector_buffer.hpp>
#include <vecmem/containers/data/jagged_vector_data.hpp>
#include <vecmem/containers/data/jagged_vector_view.hpp>
#include <vecmem/containers/data/vector_buffer.hpp>
#include <vecmem/containers/data/vector_view.hpp>

namespace traccc {

/// @name Types used to send data back and forth between host and device code
/// @{

/// Structure holding (some of the) data about the container in host code
template <typename header_t, typename item_t>
struct container_data {
    vecmem::data::vector_view<header_t> headers;
    vecmem::data::jagged_vector_data<item_t> items;
};

/// Structure holding (all of the) data about the container in host code
template <typename header_t, typename item_t>
struct container_buffer {
    vecmem::data::vector_buffer<header_t> headers;
    vecmem::data::jagged_vector_buffer<item_t> items;
};

/// Structure used to send the data about the container to device code
///
/// This is the type that can be passed to device code as-is. But since in
/// host code one needs to manage the data describing a
/// @c traccc::container either using @c traccc::container_data or
/// @c traccc::container_buffer, it needs to have constructors from
/// both of those types.
///
/// In fact it needs to be created from one of those types, as such an
/// object can only function if an instance of one of those types exists
/// alongside it as well.
///
template <typename header_t, typename item_t>
struct container_view {

    /// Constructor from a @c container_data object
    container_view(const container_data<header_t, item_t>& data)
        : headers(data.headers), items(data.items) {}

    /// Constructor from a @c container_buffer object
    container_view(const container_buffer<header_t, item_t>& buffer)
        : headers(buffer.headers), items(buffer.items) {}

    /// View of the data describing the headers
    vecmem::data::vector_view<header_t> headers;

    /// View of the data describing the items
    vecmem::data::jagged_vector_view<item_t> items;
};

/// Helper function for making a "simple" object out of the container
/// (non-const)
template <typename header_t, typename item_t>
inline container_data<header_t, item_t> get_data(
    host_container<header_t, item_t>& cc,
    vecmem::memory_resource* resource = nullptr) {
    return {{vecmem::get_data(cc.get_headers())},
            {vecmem::get_data(cc.get_items(), resource)}};
}

/// Helper function for making a "simple" object out of the container (const)
template <typename header_t, typename item_t>
inline container_data<const header_t, const item_t> get_data(
    const host_container<header_t, item_t>& cc,
    vecmem::memory_resource* resource = nullptr) {
    return {{vecmem::get_data(cc.get_headers())},
            {vecmem::get_data(cc.get_items(), resource)}};
}

}  // namespace traccc
