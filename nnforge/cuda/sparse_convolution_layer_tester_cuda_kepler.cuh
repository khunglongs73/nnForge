/*
 *  Copyright 2011-2014 Maxim Milakov
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#pragma once

#include "layer_tester_cuda.h"

#include <cuda_runtime.h>

#include <boost/format.hpp>

#include "util_cuda.h"
#include "cuda_texture.h"
#include "neural_network_cuda_exception.h"

#include "../sparse_convolution_layer.h"
#include "../nn_types.h"

#define MAX_DIMENSION_COUNT 4

#define BLOCK_WIDTH 4
#define BLOCK_HEIGHT 4

namespace nnforge
{
	namespace cuda
	{
		template<int DIMENSION_COUNT, int WINDOW_WIDTH, int WINDOW_HEIGHT>
		__launch_bounds__(256, 4)
		__global__ void sparse_convolution_tex_exact_blocked_kernel_kepler(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			const float * __restrict weights,
			const int * __restrict column_indices,
			const int * __restrict row_ptrs,
			const float * __restrict biases,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> output_block_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_elem_count_per_feature_map,
			int entry_count,
			int block_count_per_feature_map,
			int weight_count_per_block,
			unsigned int dummy)
		{
			int neuron_output_feature_map_pair_id = blockIdx.x * blockDim.x + threadIdx.x;
			int output_feature_map_id = neuron_output_feature_map_pair_id / block_count_per_feature_map;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (output_feature_map_id < output_feature_map_count);
			if (in_bounds)
			{
				int neuron_id = neuron_output_feature_map_pair_id - block_count_per_feature_map * output_feature_map_id;

				int xyzw_output[DIMENSION_COUNT];
				int remainder = neuron_id;
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT - 1; ++i)
				{
					int new_remainder = remainder / output_block_sizes[i];
					xyzw_output[i] = remainder - output_block_sizes[i] * new_remainder;
					remainder = new_remainder;
				}
				xyzw_output[DIMENSION_COUNT - 1] = remainder;
				xyzw_output[0] *= BLOCK_WIDTH;
				if (DIMENSION_COUNT > 1)
					xyzw_output[1] *= BLOCK_HEIGHT;

				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}

				int start_column_index = __load_nc(row_ptrs + output_feature_map_id);
				int end_column_index = __load_nc(row_ptrs + output_feature_map_id + 1);

				const float * current_weights = weights + weight_count_per_block * start_column_index;

				int input_elem_id_base = entry_id * input_feature_map_count;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id_base = input_elem_id_base * input_sizes[i] + xyzw[i];

				float sums[(DIMENSION_COUNT > 1 ? BLOCK_HEIGHT : 1)][BLOCK_WIDTH];

				float bias = biases[output_feature_map_id];
				#pragma unroll
				for(int i = 0; i < (DIMENSION_COUNT > 1 ? BLOCK_HEIGHT : 1); ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_WIDTH; ++j)
						sums[i][j] = bias;

				unsigned int valid_positions[(((DIMENSION_COUNT > 1) ? (WINDOW_HEIGHT + BLOCK_HEIGHT - 1) : 1) * (WINDOW_WIDTH + BLOCK_WIDTH - 1) + 31) / 32];
				#pragma unroll
				for(int i = 0; i < sizeof(valid_positions) / sizeof(unsigned int); ++i)
					valid_positions[i] = 0;
				#pragma unroll
				for(int input_yy = 0; input_yy < ((DIMENSION_COUNT > 1) ? (WINDOW_HEIGHT + BLOCK_HEIGHT - 1) : 1); ++input_yy)
				{
					int input_y = input_yy + ((DIMENSION_COUNT > 1) ? xyzw[1] : 0);
					bool b_fit1 = (DIMENSION_COUNT > 1) ? ((unsigned int)input_y < (unsigned int)input_sizes[1]) : true;
					#pragma unroll
					for(int input_xx = 0; input_xx < (WINDOW_WIDTH + BLOCK_WIDTH - 1); ++input_xx)
					{
						int input_x = input_xx + xyzw[0];
						bool b_fit0 = (b_fit1 && ((unsigned int)input_x < (unsigned int)input_sizes[0]));
						if (b_fit0)
						{
							int pos_total = input_yy * (WINDOW_WIDTH + BLOCK_WIDTH - 1) + input_xx;
							valid_positions[pos_total / 32] |= (1U << (pos_total & 31));
						}
					}
				}

				for(int nnz_index = start_column_index; nnz_index < end_column_index; ++nnz_index)
				{
					#pragma unroll
					for(int i = 0; i < sizeof(valid_positions) / sizeof(unsigned int); ++i)
						valid_positions[i] += dummy; // Hack to disable compiler putting each flag into its own 32bit register

					int input_feature_map_id = column_indices[nnz_index];
					int input_elem_id = input_elem_id_base + input_feature_map_id * input_elem_count_per_feature_map;

					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;

							float input_local_buf[(DIMENSION_COUNT > 1) ? (WINDOW_HEIGHT + BLOCK_HEIGHT - 1) : 1][WINDOW_WIDTH + BLOCK_WIDTH - 1];

							#pragma unroll
							for(int input_yy = 0; input_yy < ((DIMENSION_COUNT > 1) ? (WINDOW_HEIGHT + BLOCK_HEIGHT - 1) : 1); ++input_yy)
							{
								#pragma unroll
								for(int input_xx = 0; input_xx < (WINDOW_WIDTH + BLOCK_WIDTH - 1); ++input_xx)
								{
									int pos_total = input_yy * (WINDOW_WIDTH + BLOCK_WIDTH - 1) + input_xx;
									bool b_fit0 = b_fit2 && ((valid_positions[pos_total / 32] & (1U << (pos_total & 31))) != 0);
									int current_offset = input_elem_id + input_yy * input_sizes[0] + input_xx;
									input_local_buf[input_yy][input_xx] = tex1Dfetch<float>(input_tex, b_fit0 ? current_offset : -1);
								}
							}

							#pragma unroll
							for(int input_yy = 0; input_yy < WINDOW_HEIGHT; ++input_yy)
							{
								#pragma unroll
								for(int input_xx = 0; input_xx < WINDOW_WIDTH; ++input_xx)
								{
									float weight = __load_nc(current_weights);

									#pragma unroll
									for(int pos_y = 0; pos_y < ((DIMENSION_COUNT > 1) ? BLOCK_HEIGHT : 1); ++pos_y)
									{
										#pragma unroll
										for(int pos_x = 0; pos_x < BLOCK_WIDTH; ++pos_x)
										{
											float input_val = input_local_buf[input_yy + pos_y][input_xx + pos_x];
											sums[pos_y][pos_x] += weight * input_val;
										}
									}

									++current_weights;
								}
							}

							if (DIMENSION_COUNT > 2)
								input_elem_id += input_sizes[0] * input_sizes[1];
						} // for input_z
						if (DIMENSION_COUNT > 3)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
				} // for nnz_index

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];

				#pragma unroll
				for(int pos_y = 0; pos_y < ((DIMENSION_COUNT > 1) ? BLOCK_HEIGHT : 1); ++pos_y)
				{
					if ((DIMENSION_COUNT > 1) ? (pos_y < output_sizes[1] - xyzw_output[1]) : true)
					{
						#pragma unroll
						for(int pos_x = 0; pos_x < BLOCK_WIDTH; ++pos_x)
						{
							if (pos_x < output_sizes[0] - xyzw_output[0])
							{
								output[output_offset + pos_x] = sums[pos_y][pos_x];
							}
						}
					}
					output_offset += output_sizes[0];
				}
			} // if (in_bounds)
		}

		template<int DIMENSION_COUNT>
		__launch_bounds__(256, 4)
		__global__ void sparse_convolution_tex_generic_blocked_kernel_kepler(
			float * __restrict output,
			cudaTextureObject_t input_tex,
			const float * __restrict weights,
			const int * __restrict column_indices,
			const int * __restrict row_ptrs,
			const float * __restrict biases,
			array_by_val<int, DIMENSION_COUNT> output_sizes,
			array_by_val<int, DIMENSION_COUNT> output_block_sizes,
			array_by_val<int, DIMENSION_COUNT> input_sizes,
			array_by_val<int, DIMENSION_COUNT> window_sizes,
			array_by_val<int, DIMENSION_COUNT> left_zero_padding,
			int input_feature_map_count,
			int output_feature_map_count,
			int input_elem_count_per_feature_map,
			int entry_count,
			int block_count_per_feature_map,
			int weight_count_per_block)
		{
			int neuron_output_feature_map_pair_id = blockIdx.x * blockDim.x + threadIdx.x;
			int output_feature_map_id = neuron_output_feature_map_pair_id / block_count_per_feature_map;
			int entry_id = blockIdx.y * blockDim.y + threadIdx.y;

			bool in_bounds = (entry_id < entry_count) && (output_feature_map_id < output_feature_map_count);
			if (in_bounds)
			{
				int neuron_id = neuron_output_feature_map_pair_id - block_count_per_feature_map * output_feature_map_id;

				int xyzw_output[DIMENSION_COUNT];
				int remainder = neuron_id;
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT - 1; ++i)
				{
					int new_remainder = remainder / output_block_sizes[i];
					xyzw_output[i] = remainder - output_block_sizes[i] * new_remainder;
					remainder = new_remainder;
				}
				xyzw_output[DIMENSION_COUNT - 1] = remainder;
				xyzw_output[0] *= BLOCK_WIDTH;
				if (DIMENSION_COUNT > 1)
					xyzw_output[1] *= BLOCK_HEIGHT;

				int xyzw[DIMENSION_COUNT];
				#pragma unroll
				for(int i = 0; i < DIMENSION_COUNT; ++i)
				{
					xyzw[i] = xyzw_output[i] - left_zero_padding[i];
				}

				int start_column_index = __load_nc(row_ptrs + output_feature_map_id);
				int end_column_index = __load_nc(row_ptrs + output_feature_map_id + 1);

				const float * current_weights = weights + weight_count_per_block * start_column_index;

				int input_elem_id_base = entry_id * input_feature_map_count;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					input_elem_id_base = input_elem_id_base * input_sizes[i] + xyzw[i];

				float sums[(DIMENSION_COUNT > 1 ? BLOCK_HEIGHT : 1)][BLOCK_WIDTH];

				float bias = biases[output_feature_map_id];
				#pragma unroll
				for(int i = 0; i < (DIMENSION_COUNT > 1 ? BLOCK_HEIGHT : 1); ++i)
					#pragma unroll
					for(int j = 0; j < BLOCK_WIDTH; ++j)
						sums[i][j] = bias;

				for(int nnz_index = start_column_index; nnz_index < end_column_index; ++nnz_index)
				{
					int input_feature_map_id = column_indices[nnz_index];
					int input_elem_id = input_elem_id_base + input_feature_map_id * input_elem_count_per_feature_map;

					for(int input_w = (DIMENSION_COUNT > 3 ? xyzw[3] : 0); input_w < (DIMENSION_COUNT > 3 ? xyzw[3] + window_sizes[3] : 1); ++input_w)
					{
						bool b_fit3 = (DIMENSION_COUNT > 3) ? ((unsigned int)input_w < (unsigned int)input_sizes[3]) : true;
						for(int input_z = (DIMENSION_COUNT > 2 ? xyzw[2] : 0); input_z < (DIMENSION_COUNT > 2 ? xyzw[2] + window_sizes[2] : 1); ++input_z)
						{
							bool b_fit2 = (DIMENSION_COUNT > 2) ? (b_fit3 && ((unsigned int)input_z < (unsigned int)input_sizes[2])) : true;

							#pragma unroll 2
							for(int input_yy = 0; input_yy < ((DIMENSION_COUNT > 1) ? window_sizes[1] : 1); ++input_yy)
							{
								#pragma unroll 2
								for(int input_xx = 0; input_xx < window_sizes[0]; ++input_xx)
								{
									float weight = __load_nc(current_weights);

									#pragma unroll
									for(int pos_y = 0; pos_y < ((DIMENSION_COUNT > 1) ? BLOCK_HEIGHT : 1); ++pos_y)
									{
										bool b_fit1 = (DIMENSION_COUNT > 1) ? (b_fit2 && ((unsigned int)(xyzw[1] + input_yy + pos_y) < (unsigned int)input_sizes[1])) : true;
										#pragma unroll
										for(int pos_x = 0; pos_x < BLOCK_WIDTH; ++pos_x)
										{
											bool b_fit0 = (b_fit1 && ((unsigned int)(xyzw[0] + input_xx + pos_x) < (unsigned int)input_sizes[0]));
											int current_offset = input_elem_id + (input_yy + pos_y) * input_sizes[0] + input_xx + pos_x;
											float input_val = tex1Dfetch<float>(input_tex, b_fit0 ? current_offset : -1);
											sums[pos_y][pos_x] += weight * input_val;
										}
									}

									++current_weights;
								}
							}

							if (DIMENSION_COUNT > 2)
								input_elem_id += input_sizes[0] * input_sizes[1];
						} // for input_z
						if (DIMENSION_COUNT > 3)
							input_elem_id += input_sizes[1] * input_sizes[0] * (input_sizes[2] - window_sizes[2]);
					} // for input_w
				} // for nnz_index

				int output_offset = entry_id * output_feature_map_count + output_feature_map_id;
				#pragma unroll
				for(int i = DIMENSION_COUNT - 1; i >= 0; --i)
					output_offset = output_offset * output_sizes[i] + xyzw_output[i];

				#pragma unroll
				for(int pos_y = 0; pos_y < ((DIMENSION_COUNT > 1) ? BLOCK_HEIGHT : 1); ++pos_y)
				{
					if ((DIMENSION_COUNT > 1) ? (pos_y < output_sizes[1] - xyzw_output[1]) : true)
					{
						#pragma unroll
						for(int pos_x = 0; pos_x < BLOCK_WIDTH; ++pos_x)
						{
							if (pos_x < output_sizes[0] - xyzw_output[0])
							{
								output[output_offset + pos_x] = sums[pos_y][pos_x];
							}
						}
					}
					output_offset += output_sizes[0];
				}
			} // if (in_bounds)
		}

#define launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, window_height_const) \
	sparse_convolution_tex_exact_blocked_kernel_kepler<dimension_count_const,window_width_const,window_height_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*additional_buffers[0], input_tex, *data[0], *data_custom[0], *data_custom[1], *data[1], output_sizes, output_block_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_elem_count_per_feature_map, entry_count, block_count_per_feature_map, weight_count_per_block, 0U);

#define launch_generic_kernel_const(dimension_count_const) \
	sparse_convolution_tex_generic_blocked_kernel_kepler<dimension_count_const><<<kernel_dims.first, kernel_dims.second, 0, stream_id>>>(*additional_buffers[0], input_tex, *data[0], *data_custom[0], *data_custom[1], *data[1], output_sizes, output_block_sizes, input_sizes, window_sizes, left_zero_padding, input_configuration_specific.feature_map_count, output_configuration_specific.feature_map_count, input_elem_count_per_feature_map, entry_count, block_count_per_feature_map, weight_count_per_block);

#define launch_kernel_const_const(dimension_count_const, window_width_const, window_height) \
	if (dimension_count_const > 1) \
	{ \
		switch (window_height) \
		{ \
		case 1: \
			if (window_width_const >= 1) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 1); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 2: \
			if (window_width_const >= 2) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 2); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 3: \
			if (window_width_const >= 3) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 3); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 4: \
			if (window_width_const >= 4) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 4); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 5: \
			if (window_width_const >= 5) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 5); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 6: \
			if (window_width_const >= 6) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 6); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		case 7: \
			if (window_width_const >= 7) { launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 7); } else { launch_generic_kernel_const(dimension_count_const); } \
			break; \
		default: \
			launch_generic_kernel_const(dimension_count_const); \
			break; \
		} \
	} \
	else \
	{ \
		launch_exact_kernel_const_const_const(dimension_count_const, window_width_const, 1); \
	}

#define launch_kernel(dimension_count_const, window_width, window_height) \
	switch (window_width) \
	{ \
	case 1: \
		launch_kernel_const_const(dimension_count_const, 1, window_height); \
		break; \
	case 2: \
		launch_kernel_const_const(dimension_count_const, 2, window_height); \
		break; \
	case 3: \
		launch_kernel_const_const(dimension_count_const, 3, window_height); \
		break; \
	case 4: \
		launch_kernel_const_const(dimension_count_const, 4, window_height); \
		break; \
	case 5: \
		launch_kernel_const_const(dimension_count_const, 5, window_height); \
		break; \
	case 6: \
		launch_kernel_const_const(dimension_count_const, 6, window_height); \
		break; \
	case 7: \
		launch_kernel_const_const(dimension_count_const, 7, window_height); \
		break; \
	default: \
		launch_generic_kernel_const(dimension_count_const); \
		break; \
	};

		template<int dimension_count>
		class sparse_convolution_layer_tester_cuda_kepler : public layer_tester_cuda
		{
		public:
			sparse_convolution_layer_tester_cuda_kepler()
			{
			}

			virtual ~sparse_convolution_layer_tester_cuda_kepler()
			{
			}

			virtual void enqueue_test(
				cudaStream_t stream_id,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& schema_data,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data,
				const std::vector<const_cuda_linear_buffer_device_smart_ptr>& data_custom,
				cuda_linear_buffer_device_smart_ptr input_buffer,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers,
				unsigned int entry_count)
			{
				cuda_texture input_tex(input_buffer);

				std::pair<dim3, dim3> kernel_dims = cuda_util::get_grid_and_threadblock_sizes_sequential_access(
					*cuda_config,
					block_count_per_feature_map * output_configuration_specific.feature_map_count,
					entry_count,
					1);

				launch_kernel(dimension_count, window_sizes[0], ((dimension_count > 1) ? window_sizes[1] : 1));
			}

			virtual cuda_linear_buffer_device_smart_ptr get_output_buffer(
				cuda_linear_buffer_device_smart_ptr input_buffer,
				const std::vector<cuda_linear_buffer_device_smart_ptr>& additional_buffers)
			{
				return additional_buffers[0];
			}

		protected:
			virtual void tester_configured()
			{
				nnforge_shared_ptr<const sparse_convolution_layer> layer_derived = nnforge_dynamic_pointer_cast<const sparse_convolution_layer>(layer_schema);

				block_count_per_feature_map = 1;
				weight_count_per_block = 1;
				for(int i = 0; i < dimension_count; ++i)
				{
					window_sizes[i] = layer_derived->window_sizes[i];
					input_sizes[i] = input_configuration_specific.dimension_sizes[i];
					output_sizes[i] = output_configuration_specific.dimension_sizes[i];
					left_zero_padding[i] = layer_derived->left_zero_padding[i];

					switch (i)
					{
					case 0:
						output_block_sizes[i] = (output_sizes[i] + BLOCK_WIDTH - 1) / BLOCK_WIDTH;
						break;
					case 1:
						output_block_sizes[i] = (output_sizes[i] + BLOCK_HEIGHT - 1) / BLOCK_HEIGHT;
						break;
					default:
						output_block_sizes[i] = output_sizes[i];
						break;
					}

					block_count_per_feature_map *= output_block_sizes[i];
					weight_count_per_block *= window_sizes[i];
				}
			}

			virtual std::vector<size_t> get_sizes_of_additional_buffers_per_entry() const
			{
				std::vector<size_t> res;
				res.push_back(output_elem_count_per_entry * sizeof(float));
				return res;
			}

			virtual std::vector<unsigned int> get_linear_addressing_through_texture_per_entry() const
			{
				std::vector<unsigned int> res;
				res.push_back(input_configuration_specific.get_neuron_count());
				return res;
			}

		private:
			array_by_val<int, dimension_count> output_sizes;
			array_by_val<int, dimension_count> output_block_sizes;
			array_by_val<int, dimension_count> input_sizes;
			array_by_val<int, dimension_count> window_sizes;
			array_by_val<int, dimension_count> left_zero_padding;
			int block_count_per_feature_map;
			int weight_count_per_block;
		};
	}
}
