/*
 * TRACCC library, part of the ACTS project (R&D line)
 *
 * (c) 2022 CERN for the benefit of the ACTS project
 *
 * Mozilla Public License Version 2.0
 */

#include "traccc/cuda/cca/component_connection.hpp"
#include "traccc/cuda/utils/definitions.hpp"
#include "traccc/edm/cell.hpp"
#include "traccc/edm/cluster.hpp"
#include "traccc/edm/measurement.hpp"
#include "vecmem/containers/vector.hpp"
#include "vecmem/memory/allocator.hpp"
#include "vecmem/memory/binary_page_memory_resource.hpp"
#include "vecmem/memory/cuda/managed_memory_resource.hpp"

namespace {
static constexpr std::size_t MAX_CELLS_PER_PARTITION = 2048;
static constexpr std::size_t THREADS_PER_BLOCK = 256;
using index_t = unsigned short;
}  // namespace

namespace traccc::cuda {
namespace details {
struct ccl_partition {
    std::size_t start;
    std::size_t size;
};

struct cell_container {
    std::size_t size = 0;
    channel_id* channel0 = nullptr;
    channel_id* channel1 = nullptr;
    scalar* activation = nullptr;
    scalar* time = nullptr;
    geometry_id* module_id = nullptr;
};

struct measurement_container {
    unsigned int size = 0;
    scalar* channel0 = nullptr;
    scalar* channel1 = nullptr;
    scalar* variance0 = nullptr;
    scalar* variance1 = nullptr;
    geometry_id* module_id = nullptr;
};

__device__ bool is_adjacent(channel_id ac0, channel_id ac1, channel_id bc0,
                            channel_id bc1) {
    unsigned int p0 = (ac0 - bc0);
    unsigned int p1 = (ac1 - bc1);

    return p0 * p0 <= 1 && p1 * p1 <= 1;
}

__device__ void reduce_problem_cell(cell_container& cells, index_t tid,
                                    unsigned char& adjc, index_t adjv[]) {
    /*
     * The number of adjacent cells for each cell must start at zero, to
     * avoid uninitialized memory. adjv does not need to be zeroed, as
     * we will only access those values if adjc indicates that the value
     * is set.
     */
    adjc = 0;

    channel_id c0 = cells.channel0[tid];
    channel_id c1 = cells.channel1[tid];
    geometry_id gid = cells.module_id[tid];

    /*
     * First, we traverse the cells backwards, starting from the current
     * cell and working back to the first, collecting adjacent cells
     * along the way.
     */
    for (index_t j = tid - 1; j < tid; --j) {
        /*
         * Since the data is sorted, we can assume that if we see a cell
         * sufficiently far away in both directions, it becomes
         * impossible for that cell to ever be adjacent to this one.
         * This is a small optimisation.
         */
        if (cells.channel1[j] + 1 < c1 || cells.module_id[j] != gid) {
            break;
        }

        /*
         * If the cell examined is adjacent to the current cell, save it
         * in the current cell's adjacency set.
         */
        if (is_adjacent(c0, c1, cells.channel0[j], cells.channel1[j])) {
            adjv[adjc++] = j;
        }
    }

    /*
     * Now we examine all the cells past the current one, using almost
     * the same logic as in the backwards pass.
     */
    for (index_t j = tid + 1; j < cells.size; ++j) {
        /*
         * Note that this check now looks in the opposite direction! An
         * important difference.
         */
        if (cells.channel1[j] > c1 + 1 || cells.module_id[j] != gid) {
            break;
        }

        if (is_adjacent(c0, c1, cells.channel0[j], cells.channel1[j])) {
            adjv[adjc++] = j;
        }
    }
}

__device__ void fast_sv_1(index_t* f, index_t* gf, unsigned char adjc[],
                          index_t adjv[][8], unsigned int size) {
    /*
     * The algorithm finishes if an iteration leaves the arrays unchanged.
     * This varible will be set if a change is made, and dictates if another
     * loop is necessary.
     */
    bool gfc;

    do {
        /*
         * Reset the end-parameter to false, so we can set it to true if we
         * make a change to our arrays.
         */
        gfc = false;

        /*
         * The algorithm executes in a loop of three distinct parallel
         * stages. In this first one, we examine adjacent cells and copy
         * their cluster ID if it is lower than our, essentially merging
         * the two together.
         */
        for (index_t tst = 0, tid;
             (tid = tst * blockDim.x + threadIdx.x) < size; ++tst) {
            __builtin_assume(adjc[tst] <= 8);

            for (unsigned char k = 0; k < adjc[tst]; ++k) {
                index_t q = gf[adjv[tst][k]];

                if (gf[tid] > q) {
                    f[f[tid]] = q;
                    f[tid] = q;
                }
            }
        }

        /*
         * Each stage in this algorithm must be preceded by a
         * synchronization barrier!
         */
        __syncthreads();

        /*
         * The second stage is shortcutting, which is an optimisation that
         * allows us to look at any shortcuts in the cluster IDs that we
         * can merge without adjacency information.
         */
        for (index_t tid = threadIdx.x; tid < size; tid += blockDim.x) {
            if (f[tid] > gf[tid]) {
                f[tid] = gf[tid];
            }
        }

        /*
         * Synchronize before the final stage.
         */
        __syncthreads();

        /*
         * Update the array for the next generation, keeping track of any
         * changes we make.
         */
        for (index_t tid = threadIdx.x; tid < size; tid += blockDim.x) {
            if (gf[tid] != f[f[tid]]) {
                gf[tid] = f[f[tid]];
                gfc = true;
            }
        }

        /*
         * To determine whether we need another iteration, we use block
         * voting mechanics. Each thread checks if it has made any changes
         * to the arrays, and votes. If any thread votes true, all threads
         * will return a true value and go to the next iteration. Only if
         * all threads return false will the loop exit.
         */
    } while (__syncthreads_or(gfc));
}

__device__ void fast_sv_2(index_t* f, index_t* gf, unsigned char adjc[],
                          index_t adjv[][8], unsigned int size) {
    bool gfc;

    do {
        gfc = false;

        for (index_t tst = 0, tid;
             (tid = tst * blockDim.x + threadIdx.x) < size; ++tst) {
            for (unsigned char k = 0; k < adjc[tst]; ++k) {
                index_t j = adjv[tst][k];

                if (f[f[j]] < gf[f[tid]]) {
                    gf[f[tid]] = f[f[j]];
                    gfc = true;
                }
            }
        }

        __syncthreads();

        for (index_t tst = 0, tid;
             (tid = tst * blockDim.x + threadIdx.x) < size; ++tst) {
            for (unsigned char k = 0; k < adjc[tst]; ++k) {
                index_t j = adjv[tst][k];

                if (f[f[j]] < gf[tid]) {
                    gf[tid] = f[f[j]];
                    gfc = true;
                }
            }
        }

        __syncthreads();

        for (index_t tst = 0, tid;
             (tid = tst * blockDim.x + threadIdx.x) < size; ++tst) {
            if (f[f[tid]] < gf[tid]) {
                gf[tid] = f[f[tid]];
                gfc = true;
            }
        }

        __syncthreads();

        for (index_t tst = 0, tid;
             (tid = tst * blockDim.x + threadIdx.x) < size; ++tst) {
            f[tid] = gf[tid];
        }
    } while (__syncthreads_or(gfc));
}

__device__ void aggregate_clusters(const cell_container& cells,
                                   measurement_container& out, index_t* f) {
    __shared__ unsigned int outi;

    if (threadIdx.x == 0) {
        outi = 0;
    }

    __syncthreads();

    /*
     * This is the post-processing stage, where we merge the clusters into a
     * single measurement and write it to the output.
     */
    for (index_t tst = 0, tid;
         (tid = tst * blockDim.x + threadIdx.x) < cells.size; ++tst) {

        /*
         * If and only if the value in the work arrays is equal to the index
         * of a cell, that cell is the "parent" of a cluster of cells. If
         * they are not, there is nothing for us to do. Easy!
         */
        if (f[tid] == tid) {
            /*
             * If we are a cluster owner, atomically claim a position in the
             * output array which we can write to.
             */
            unsigned int id = atomicAdd(&outi, 1);

            /*
             * These variables keep track of the sums of X and Y coordinates
             * for the final coordinates, the total activation weight, as
             * well as the sum of squares of positions, which we use to
             * calculate the variance.
             */
            float sw = 0.0;
            float mx = 0.0, my = 0.0;
            float vx = 0.0, vy = 0.0;

            /*
             * Now, we iterate over all other cells to check if they belong
             * to our cluster. Note that we can start at the current index
             * because no cell is every a child of a cluster owned by a cell
             * with a higher ID.
             */
            for (index_t j = tid; j < cells.size; j++) {
                /*
                 * If the value of this cell is equal to our, that means it
                 * is part of our cluster. In that case, we take its values
                 * for position and add them to our accumulators.
                 */
                if (f[j] == tid) {
                    float w = cells.activation[j];

                    sw += w;

                    float pmx = mx, pmy = my;
                    float dx = cells.channel0[j] - pmx;
                    float dy = cells.channel1[j] - pmy;
                    float wf = w / sw;

                    mx = pmx + wf * dx;
                    my = pmy + wf * dy;

                    vx += w * dx * (cells.channel0[j] - mx);
                    vy += w * dy * (cells.channel1[j] - my);
                }
            }

            /*
             * Write the average weighted x and y coordinates, as well as
             * the weighted average square position, to the output array.
             */
            out.channel0[id] = mx;
            out.channel1[id] = my;
            out.variance0[id] = vx / sw;
            out.variance1[id] = vy / sw;
            out.module_id[id] = cells.module_id[tid];
        }
    }
}

__global__ __launch_bounds__(THREADS_PER_BLOCK) void sparse_ccl_kernel(
    const cell_container container, const ccl_partition* partitions,
    measurement_container& _out_ctnr) {
    const ccl_partition& partition = partitions[blockIdx.x];

    /*
     * Seek the correct cell region in the input data. Again, this is all a
     * contiguous block of memory for now, and we use the blocks array to
     * define the different ranges per block/module. At the end of this we
     * have the starting address of the block of cells dedicated to this
     * module, and we have its size.
     */
    cell_container cells;
    cells.size = partition.size;
    cells.channel0 = &container.channel0[partition.start];
    cells.channel1 = &container.channel1[partition.start];
    cells.activation = &container.activation[partition.start];
    cells.time = &container.time[partition.start];
    cells.module_id = &container.module_id[partition.start];

    assert(cells.size <= MAX_CELLS_PER_PARTITION);

    /*
     * As an optimisation, we will keep track of which cells are adjacent to
     * each other cell. To do this, we define, in thread-local memory or
     * registers, up to eight adjacent cell indices and we keep track of how
     * many adjacent cells there are (i.e. adjc[i] determines how many of
     * the eight values in adjv[i] are actually meaningful).
     *
     * The implementation is such that a thread might need to process more
     * than one hit. As such, we keep one counter and eight indices _per_
     * hit the thread is processing. This number is never larger than
     * the max number of activations per module divided by the threads per
     * block.
     */
    index_t adjv[MAX_CELLS_PER_PARTITION / THREADS_PER_BLOCK][8];
    unsigned char adjc[MAX_CELLS_PER_PARTITION / THREADS_PER_BLOCK];

    /*
     * After this is all done, we synchronise the block. I am not absolutely
     * certain that this is necessary here, but the overhead is not that big
     * and we might as well be safe rather than sorry.
     */
    __syncthreads();

    /*
     * This loop initializes the adjacency cache, which essentially
     * translates the sparse CCL problem into a graph CCL problem which we
     * can tackle with well-studied algorithms. This loop pattern is often
     * found throughout this code. We iterate over the number of activations
     * each thread must process. Sadly, the CUDA limit is 1024 threads per
     * block and we cannot guarantee that there will be fewer than 1024
     * activations in a module. So each thread must be able to do more than
     * one.
     */
    for (index_t tst = 0, tid;
         (tid = tst * blockDim.x + threadIdx.x) < cells.size; ++tst) {
        reduce_problem_cell(cells, tid, adjc[tst], adjv[tst]);
    }

    // if (threadIdx.x == 0) asm("mov.u32 %0, %clock;" : "=r"(c2) );

    /*
     * These arrays are the meat of the pudding of this algorithm, and we
     * will constantly be writing and reading from them which is why we
     * declare them to be in the fast shared memory. Note that this places a
     * limit on the maximum activations per module, as the amount of shared
     * memory is limited. These could always be moved to global memory, but
     * the algorithm would be decidedly slower in that case.
     */
    __shared__ index_t f[MAX_CELLS_PER_PARTITION], gf[MAX_CELLS_PER_PARTITION];

    for (index_t tst = 0, tid;
         (tid = tst * blockDim.x + threadIdx.x) < cells.size; ++tst) {
        /*
         * At the start, the values of f and gf should be equal to the ID of
         * the cell.
         */
        f[tid] = tid;
        gf[tid] = tid;
    }

    /*
     * Now that the data has initialized, we synchronize again before we
     * move onto the actual processing part.
     */
    __syncthreads();

    fast_sv_1(f, gf, adjc, adjv, cells.size);

    /*
     * This variable will be used to write to the output later.
     */
    __shared__ unsigned int outi;

    if (threadIdx.x == 0) {
        outi = 0;
    }

    __syncthreads();

    for (index_t tst = 0, tid;
         (tid = tst * blockDim.x + threadIdx.x) < cells.size; ++tst) {
        if (f[tid] == tid) {
            atomicAdd(&outi, 1);
        }
    }

    __syncthreads();

    if (threadIdx.x == 0) {
        outi = atomicAdd(&_out_ctnr.size, outi);
    }

    __syncthreads();

    measurement_container out;
    out.channel0 = &_out_ctnr.channel0[outi];
    out.channel1 = &_out_ctnr.channel1[outi];
    out.variance0 = &_out_ctnr.variance0[outi];
    out.variance1 = &_out_ctnr.variance1[outi];
    out.module_id = &_out_ctnr.module_id[outi];

    aggregate_clusters(cells, out, f);
}

vecmem::vector<details::ccl_partition> partition(
    const host_cell_container& data, vecmem::memory_resource& mem) {
    vecmem::vector<details::ccl_partition> partitions(&mem);
    std::size_t index = 0;
    std::size_t size = 0;

    for (std::size_t i = 0; i < data.size(); ++i) {
        channel_id last_mid = 0;

        for (const cell& c : data.at(i).items) {
            if (c.channel1 > last_mid + 1 && size >= 2 * THREADS_PER_BLOCK) {
                partitions.push_back(
                    details::ccl_partition{.start = index, .size = size});

                index += size;
                size = 0;
            }

            last_mid = c.channel1;
            size += 1;
        }

        if (size >= 2 * THREADS_PER_BLOCK) {
            partitions.push_back(
                details::ccl_partition{.start = index, .size = size});

            index += size;
            size = 0;
        }
    }

    if (size > 0) {
        partitions.push_back(
            details::ccl_partition{.start = index, .size = size});
    }

    return partitions;
}
}  // namespace details

host_measurement_container component_connection::operator()(
    const host_cell_container& data) const {
    vecmem::cuda::managed_memory_resource upstream;
    vecmem::binary_page_memory_resource mem(upstream);

    std::size_t total_cells = 0;

    for (std::size_t i = 0; i < data.size(); ++i) {
        total_cells += data.at(i).items.size();
    }

    details::cell_container container;

    vecmem::vector<channel_id> channel0(&mem);
    channel0.reserve(total_cells);
    vecmem::vector<channel_id> channel1(&mem);
    channel1.reserve(total_cells);
    vecmem::vector<scalar> activation(&mem);
    activation.reserve(total_cells);
    vecmem::vector<scalar> time(&mem);
    time.reserve(total_cells);
    vecmem::vector<geometry_id> module_id(&mem);
    module_id.reserve(total_cells);

    for (std::size_t i = 0; i < data.size(); ++i) {
        for (std::size_t j = 0; j < data.at(i).items.size(); ++j) {
            channel0.push_back(data.at(i).items.at(j).channel0);
            channel1.push_back(data.at(i).items.at(j).channel1);
            activation.push_back(data.at(i).items.at(j).activation);
            time.push_back(data.at(i).items.at(j).time);
            module_id.push_back(data.at(i).header.module);
        }
    }

    container.size = total_cells;
    container.channel0 = channel0.data();
    container.channel1 = channel1.data();
    container.activation = activation.data();
    container.time = time.data();
    container.module_id = module_id.data();

    vecmem::vector<details::ccl_partition> partitions =
        details::partition(data, mem);

    vecmem::allocator alloc(mem);

    details::measurement_container* mctnr =
        alloc.new_object<details::measurement_container>();

    mctnr->channel0 = static_cast<scalar*>(
        alloc.allocate_bytes(total_cells * sizeof(scalar)));
    mctnr->channel1 = static_cast<scalar*>(
        alloc.allocate_bytes(total_cells * sizeof(scalar)));
    mctnr->variance0 = static_cast<scalar*>(
        alloc.allocate_bytes(total_cells * sizeof(scalar)));
    mctnr->variance1 = static_cast<scalar*>(
        alloc.allocate_bytes(total_cells * sizeof(scalar)));
    mctnr->module_id = static_cast<geometry_id*>(
        alloc.allocate_bytes(total_cells * sizeof(geometry_id)));

    sparse_ccl_kernel<<<partitions.size(), THREADS_PER_BLOCK>>>(
        container, partitions.data(), *mctnr);

    CUDA_ERROR_CHECK(cudaDeviceSynchronize());

    host_measurement_container out;

    for (std::size_t i = 0; i < data.size(); ++i) {
        vecmem::vector<measurement> v(&mem);

        for (std::size_t j = 0; j < mctnr->size; ++j) {
            if (mctnr->module_id[j] == data.at(i).header.module) {
                measurement m;

                m.local = {mctnr->channel0[j], mctnr->channel1[j]};
                m.variance = {mctnr->variance0[j], mctnr->variance1[j]};

                v.push_back(m);
            }
        }

        out.push_back(cell_module(data.at(i).header), std::move(v));
    }

    return out;
}
}  // namespace traccc::cuda
