/*
 *  Copyright 2011-2013 Maxim Milakov
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

#include "network_updater_plain.h"

#include <stack>

#include <boost/format.hpp>

#include "layer_tester_plain_factory.h"
#include "layer_updater_plain_factory.h"
#include "../neural_network_exception.h"

namespace nnforge
{
	namespace plain
	{
		unsigned int network_updater_plain::max_entry_count_in_single_batch = 1024;

		network_updater_plain::network_updater_plain(
			network_schema_smart_ptr schema,
			const_data_scale_params_smart_ptr scale_params,
			plain_running_configuration_const_smart_ptr plain_config)
			: network_updater(schema, scale_params)
			, plain_config(plain_config)
		{
			const const_layer_list& layer_list = *schema;

			testing_layer_count = 0;
			start_layer_nonempty_weights_iterator = layer_list.begin();
			for(const_layer_list::const_iterator it = layer_list.begin(); it != layer_list.end(); ++it)
			{
				start_layer_nonempty_weights_iterator = it;

				if (!(*it)->is_empty_data())
					break;

				testing_layer_count++;
			}

			for(const_layer_list::const_iterator it = layer_list.begin(); it != start_layer_nonempty_weights_iterator; ++it)
				tester_list.push_back(single_layer_tester_plain_factory::get_const_instance().get_tester_plain_layer((*it)->get_uuid()));

			for(const_layer_list::const_iterator it = start_layer_nonempty_weights_iterator; it != layer_list.end(); ++it)
				updater_list.push_back(single_layer_updater_plain_factory::get_const_instance().get_updater_plain_layer((*it)->get_uuid()));
		}

		network_updater_plain::~network_updater_plain()
		{
		}

		std::vector<testing_result_smart_ptr> network_updater_plain::actual_update(
			supervised_data_reader_byte& reader,
			const std::vector<network_data_smart_ptr>& training_speed_vector_list,
			std::vector<network_data_smart_ptr>& data_list,
			const std::map<unsigned int, float>& layer_to_dropout_rate_map,
			const std::vector<float>& random_uniform_list)
		{
			std::vector<testing_result_smart_ptr> res;

			unsigned int min_dropout_layer_id = testing_layer_count + 1;
			for(std::map<unsigned int, float>::const_iterator it = layer_to_dropout_rate_map.begin(); it != layer_to_dropout_rate_map.end(); ++it)
				if (it->first < min_dropout_layer_id)
					throw neural_network_exception((boost::format("Unable to apply dropout to layer %1%") % it->first).str());

			const unsigned int input_neuron_count = reader.get_input_configuration().get_neuron_count();
			const unsigned int output_neuron_count = reader.get_output_configuration().get_neuron_count();
			const unsigned int input_feature_map_count = reader.get_input_configuration().feature_map_count;
			const unsigned int neuron_count_per_input_feature_map = reader.get_input_configuration().get_neuron_count_per_feature_map();

			unsigned int updater_entry_count = static_cast<unsigned int>(data_list.size());

			if (updater_entry_count == 0)
				return res;

			for(unsigned int i = 0; i < training_speed_vector_list.size(); ++i)
				res.push_back(testing_result_smart_ptr(new testing_result(output_neuron_count)));

			buffer_plain_size_configuration buffers_config;
			update_buffers_configuration(buffers_config, updater_entry_count);
			buffers_config.add_per_entry_buffer(input_neuron_count * sizeof(unsigned char)); // input
			buffers_config.add_per_entry_buffer(input_neuron_count * sizeof(float)); // converted input
			buffers_config.add_per_entry_buffer(output_neuron_count * sizeof(float)); // output
			buffers_config.add_constant_buffer(output_neuron_count * sizeof(float) * updater_entry_count); // temp_mse
			buffers_config.add_constant_buffer(output_neuron_count * sizeof(float) * updater_entry_count); // initial error
			for(std::vector<network_data_smart_ptr>::iterator it3 = data_list.begin(); it3 != data_list.end(); ++it3)
			{
				for(std::vector<layer_data_smart_ptr>::iterator it = (*it3)->begin(); it != (*it3)->end(); ++it)
				{
					for(layer_data::const_iterator it2 = (*it)->begin(); it2 != (*it)->end(); ++it2)
					{
						buffers_config.add_constant_buffer(it2->size() * sizeof(float)); // data
						buffers_config.add_constant_buffer(it2->size() * sizeof(float)); // training speed
					}
				}
			}

			std::vector<layer_data_list> data_list_reorganized(data_list[0]->size() - testing_layer_count);
			for(unsigned int layer_id = testing_layer_count; layer_id < data_list[0]->size(); ++layer_id)
				for(unsigned int updater_entry_id = 0; updater_entry_id < updater_entry_count; ++updater_entry_id)
					data_list_reorganized[layer_id - testing_layer_count].push_back((*data_list[updater_entry_id])[layer_id]);

			std::vector<layer_data_list> training_speed_vector_list_reorganized(training_speed_vector_list[0]->size() - testing_layer_count);
			for(unsigned int layer_id = testing_layer_count; layer_id < training_speed_vector_list[0]->size(); ++layer_id)
				for(unsigned int updater_entry_id = 0; updater_entry_id < updater_entry_count; ++updater_entry_id)
					training_speed_vector_list_reorganized[layer_id - testing_layer_count].push_back((*training_speed_vector_list[updater_entry_id])[layer_id]);

			unsigned int max_entry_count = std::min<unsigned int>(std::min<unsigned int>(plain_config->get_max_entry_count(buffers_config), reader.get_entry_count()), max_entry_count_in_single_batch);

			std::vector<unsigned char> input_buf(max_entry_count * input_neuron_count);
			std::vector<float> actual_output_buf(max_entry_count * input_neuron_count);
			additional_buffer_smart_ptr initial_error_buf(new std::vector<float>(updater_entry_count * output_neuron_count));
			additional_buffer_smart_ptr temp_mse_buf(new std::vector<float>(updater_entry_count * output_neuron_count, 0.0F));
			additional_buffer_smart_ptr input_converted_buf(new std::vector<float>(input_neuron_count * max_entry_count));

			additional_buffer_smart_ptr output_buffer = input_converted_buf;
			std::vector<std::pair<additional_buffer_smart_ptr, additional_buffer_set> > input_buffer_and_additional_testing_buffers_pack;
			std::vector<std::pair<additional_buffer_smart_ptr, updater_additional_buffer_set> > input_buffer_and_additional_updater_buffers_pack;
			{
				const const_layer_list& layer_list = *schema;
				const_layer_list::const_iterator layer_it = layer_list.begin();
				layer_configuration_specific_list::const_iterator input_config_it = layer_config_list.begin();
				for(std::vector<const_layer_tester_plain_smart_ptr>::const_iterator it = tester_list.begin(); it != tester_list.end(); ++it, ++layer_it, ++input_config_it)
				{
					additional_buffer_set additional_buffers = (*it)->allocate_additional_buffers(
						max_entry_count,
						*layer_it,
						*input_config_it,
						*(input_config_it + 1),
						plain_config);
					input_buffer_and_additional_testing_buffers_pack.push_back(std::make_pair<additional_buffer_smart_ptr, additional_buffer_set>(output_buffer, additional_buffers));
					output_buffer = (*it)->get_output_buffer(output_buffer, additional_buffers);
				}
				for(const_layer_updater_plain_list::const_iterator it = updater_list.begin(); it != updater_list.end(); ++it, ++layer_it, ++input_config_it)
				{
					updater_additional_buffer_set additional_buffers = (*it)->allocate_additional_buffers(
						updater_entry_count,
						*layer_it,
						*input_config_it,
						*(input_config_it + 1),
						plain_config,
						(it != updater_list.begin()));
					input_buffer_and_additional_updater_buffers_pack.push_back(std::make_pair<additional_buffer_smart_ptr, updater_additional_buffer_set>(output_buffer, additional_buffers));
					output_buffer = additional_buffers.output_neurons_buffer;
				}
			}
			{
				additional_buffer_smart_ptr output_errors = initial_error_buf;
				for(std::vector<std::pair<additional_buffer_smart_ptr, updater_additional_buffer_set> >::reverse_iterator it = input_buffer_and_additional_updater_buffers_pack.rbegin(); it != input_buffer_and_additional_updater_buffers_pack.rend() - 1; ++it)
				{
					if (it->second.input_errors_buffer != 0)
						output_errors = it->second.input_errors_buffer;
					else
						it->second.input_errors_buffer = output_errors;
				}
			}

			std::tr1::variate_generator<random_generator, std::tr1::uniform_int<unsigned int> > gen_random_offset(
				rnd::get_random_generator(),
				std::tr1::uniform_int<unsigned int>(0, static_cast<unsigned int>(random_uniform_list.size() - 1)));
			unsigned int mask = static_cast<unsigned int>(random_uniform_list.size() - 1);
			bool entries_remained_for_loading = true;
			while (entries_remained_for_loading)
			{
				unsigned int entries_available_for_processing_count = 0;
				while(entries_available_for_processing_count < max_entry_count)
				{
					bool entry_read = reader.read(
						&(*(input_buf.begin() + (input_neuron_count * entries_available_for_processing_count))),
						&(*(actual_output_buf.begin() + (output_neuron_count * entries_available_for_processing_count))));
					if (!entry_read)
					{
						entries_remained_for_loading = false;
						break;
					}
					entries_available_for_processing_count++;
				}

				if (entries_available_for_processing_count == 0)
					break;

				const unsigned int const_entries_available_for_processing_count = entries_available_for_processing_count;

				// Convert input
				{
					const int elem_count = static_cast<int>(const_entries_available_for_processing_count);
					const std::vector<float>::iterator input_converted_buf_it_start = input_converted_buf->begin();
					const std::vector<unsigned char>::const_iterator input_buf_it_start = input_buf.begin();
					#pragma omp parallel for default(none) schedule(guided) num_threads(plain_config->openmp_thread_count)
					for(int i = 0; i < elem_count; ++i)
					{
						std::vector<float>::iterator input_converted_buf_it = input_converted_buf_it_start + (i * input_neuron_count);
						std::vector<unsigned char>::const_iterator input_buf_it = input_buf_it_start + (i * input_neuron_count);
						for(unsigned int feature_map_id = 0; feature_map_id < input_feature_map_count; ++feature_map_id)
						{
							float addition = current_scale_params->addition_list[feature_map_id];
							float multiplication = current_scale_params->multiplication_list[feature_map_id];
							for(unsigned int j = 0; j < neuron_count_per_input_feature_map; ++j)
							{
								*input_converted_buf_it = ((static_cast<float>(*input_buf_it) * (1.0F / 255.0F)) + addition) * multiplication;
								input_converted_buf_it++;
								input_buf_it++;
							}
						}
					}
				}

				// Run testing layers
				const const_layer_list& layer_list = *schema;
				{
					const_layer_list::const_iterator layer_it = layer_list.begin();
					layer_configuration_specific_list::const_iterator input_config_it = layer_config_list.begin();
					std::vector<std::pair<additional_buffer_smart_ptr, additional_buffer_set> >::iterator buffers_it = input_buffer_and_additional_testing_buffers_pack.begin();
					for(std::vector<const_layer_tester_plain_smart_ptr>::const_iterator it = tester_list.begin(); it != tester_list.end(); ++it, ++layer_it, ++input_config_it, ++buffers_it)
					{
						(*it)->test(
							buffers_it->first,
							buffers_it->second,
							plain_config,
							*layer_it,
							const_layer_data_smart_ptr(),
							*input_config_it,
							*(input_config_it + 1),
							entries_available_for_processing_count);
					}
				}

				for(unsigned int input_entry_id = 0; input_entry_id < entries_available_for_processing_count; ++input_entry_id)
				{
					std::stack<unsigned int> offset_list;

					// Forward updater
					{
						const_layer_list::const_iterator layer_it = layer_list.begin() + testing_layer_count;
						layer_configuration_specific_list::const_iterator input_config_it = layer_config_list.begin() + testing_layer_count;
						std::vector<std::pair<additional_buffer_smart_ptr, updater_additional_buffer_set> >::iterator updater_buffers_it = input_buffer_and_additional_updater_buffers_pack.begin();
						std::vector<layer_data_list>::const_iterator data_it = data_list_reorganized.begin();
						unsigned int layer_id = testing_layer_count;
						for(std::vector<const_layer_updater_plain_smart_ptr>::const_iterator it = updater_list.begin(); it != updater_list.end(); ++it, ++layer_it, ++input_config_it, ++updater_buffers_it, ++data_it, ++layer_id)
						{
							if (it != updater_list.begin())
							{
								std::map<unsigned int, float>::const_iterator dropout_it = layer_to_dropout_rate_map.find(layer_id);
								if (dropout_it != layer_to_dropout_rate_map.end())
								{
									unsigned int offset = gen_random_offset();
									offset_list.push(offset);
									(*it)->forward_dropout(
										random_uniform_list,
										updater_buffers_it->first,
										*input_config_it,
										plain_config,
										dropout_it->second,
										mask,
										updater_entry_count,
										offset);
								}
							}

							(*it)->test(
								updater_buffers_it->first,
								updater_buffers_it->second.output_neurons_buffer,
								updater_buffers_it->second.additional_buffers,
								plain_config,
								*layer_it,
								*data_it,
								*input_config_it,
								*(input_config_it + 1),
								updater_entry_count,
								(it == updater_list.begin()) ? input_entry_id : -1);
						}
					}

					// Set initial error and compute temporary MSE
					{
						const int elem_count = static_cast<int>(output_neuron_count * updater_entry_count);
						const std::vector<float>::iterator initial_error_it = initial_error_buf->begin();
						const std::vector<float>::iterator temp_mse_it = temp_mse_buf->begin();
						const std::vector<float>::const_iterator actual_output_buf_it = actual_output_buf.begin() + (output_neuron_count * input_entry_id);
						const std::vector<float>::const_iterator output_buffer_it = output_buffer->begin();
						#pragma omp parallel for default(none) schedule(guided) num_threads(plain_config->openmp_thread_count)
						for(int i = 0; i < elem_count; ++i)
						{
							int elem_id = i % output_neuron_count;
							float err = *(actual_output_buf_it + elem_id) - *(output_buffer_it + i);
							*(initial_error_it + i) = err;
							*(temp_mse_it + i) += (err * err);
						}
					}

					// Run backward and update weights
					{
						const_layer_list::const_reverse_iterator layer_it = layer_list.rbegin();
						std::vector<std::pair<additional_buffer_smart_ptr, updater_additional_buffer_set> >::reverse_iterator updater_buffers_it = input_buffer_and_additional_updater_buffers_pack.rbegin();
						layer_configuration_specific_list::const_reverse_iterator input_config_it = layer_config_list.rbegin();
						std::vector<layer_data_list>::reverse_iterator data_it = data_list_reorganized.rbegin();
						std::vector<layer_data_list>::const_reverse_iterator training_speed_it = training_speed_vector_list_reorganized.rbegin();
						additional_buffer_smart_ptr output_errors = initial_error_buf;
						unsigned int reverse_layer_id = static_cast<unsigned int>(updater_list.size() + testing_layer_count) - 1;
						for(std::vector<const_layer_updater_plain_smart_ptr>::const_reverse_iterator it = updater_list.rbegin(); it != updater_list.rend(); ++it, ++layer_it, ++input_config_it, ++updater_buffers_it, ++data_it, ++training_speed_it, --reverse_layer_id)
						{
							if (it != updater_list.rend() - 1)
							{
								(*it)->backprop(
									updater_buffers_it->second.input_errors_buffer,
									updater_buffers_it->first,
									output_errors,
									updater_buffers_it->second.output_neurons_buffer,
									updater_buffers_it->second.additional_buffers,
									plain_config,
									*layer_it,
									*data_it,
									*(input_config_it + 1),
									*input_config_it,
									updater_entry_count);

								std::map<unsigned int, float>::const_iterator dropout_it = layer_to_dropout_rate_map.find(reverse_layer_id);
								if (dropout_it != layer_to_dropout_rate_map.end())
								{
									unsigned int offset = offset_list.top();
									offset_list.pop();
									(*it)->backward_dropout(
										random_uniform_list,
										updater_buffers_it->second.input_errors_buffer,
										*input_config_it,
										plain_config,
										dropout_it->second,
										mask,
										updater_entry_count,
										offset);
								}
							}

							(*it)->update_weights(
								updater_buffers_it->first,
								output_errors,
								updater_buffers_it->second.additional_buffers,
								*data_it,
								*training_speed_it,
								plain_config,
								*layer_it,
								*(input_config_it + 1),
								*input_config_it,
								updater_entry_count,
								(it == updater_list.rend() - 1) ? input_entry_id : -1);

							output_errors = updater_buffers_it->second.input_errors_buffer;
						}
					}
				}

				{
					const int elem_count = static_cast<int>(output_neuron_count * updater_entry_count);
					const std::vector<float>::iterator temp_mse_it = temp_mse_buf->begin();
					const std::vector<testing_result_smart_ptr>::iterator res_it = res.begin();
					#pragma omp parallel for default(none) schedule(guided) num_threads(plain_config->openmp_thread_count)
					for(int i = 0; i < elem_count; ++i)
					{
						float t = *(temp_mse_it + i) * 0.5F;
						unsigned int updater_entry_id = i / output_neuron_count;
						unsigned int output_neuron_id = i - (updater_entry_id * output_neuron_count);
						(*(res_it + updater_entry_id))->cumulative_mse_list[output_neuron_id] += t;
						*(temp_mse_it + i) = 0.0F;
					}
				}

				for(std::vector<testing_result_smart_ptr>::iterator it = res.begin(); it != res.end(); ++it)
					(*it)->entry_count += entries_available_for_processing_count;

				if (profile_mode)
				{
					entries_remained_for_loading = false;
					entry_count_updated_in_profile_mode = entries_available_for_processing_count;
				}
			}

			return res;
		}

		void network_updater_plain::layer_config_list_modified()
		{
		}

		unsigned int network_updater_plain::get_max_batch_size() const
		{
			buffer_plain_size_configuration buffer_configuration;

			const const_layer_list& layer_list = *schema;
			const_layer_list::const_iterator layer_it = layer_list.begin();
			layer_configuration_specific_list::const_iterator input_config_it = layer_config_list.begin();
			for(const_layer_updater_plain_list::const_iterator it = updater_list.begin(); it != updater_list.end(); ++it, ++layer_it, ++input_config_it)
			{
				(*it)->update_buffer_configuration(
					buffer_configuration,
					*layer_it,
					*input_config_it,
					*(input_config_it + 1),
					plain_config,
					(it != updater_list.begin()));
			}

			return plain_config->get_max_entry_count(buffer_configuration, 0.5F);
		}

		void network_updater_plain::update_buffers_configuration(
			buffer_plain_size_configuration& buffer_configuration,
			unsigned int updater_entry_count) const
		{
			const const_layer_list& layer_list = *schema;
			const_layer_list::const_iterator layer_it = layer_list.begin();
			layer_configuration_specific_list::const_iterator input_config_it = layer_config_list.begin();
			for(const_layer_tester_plain_list::const_iterator it = tester_list.begin(); it != tester_list.end(); ++it, ++layer_it, ++input_config_it)
			{
				(*it)->update_buffer_configuration(
					buffer_configuration,
					*layer_it,
					*input_config_it,
					*(input_config_it + 1),
					plain_config);
			}
			for(const_layer_updater_plain_list::const_iterator it = updater_list.begin(); it != updater_list.end(); ++it, ++layer_it, ++input_config_it)
			{
				(*it)->update_buffer_configuration(
					buffer_configuration,
					*layer_it,
					*input_config_it,
					*(input_config_it + 1),
					plain_config,
					(it != updater_list.begin()),
					updater_entry_count);
			}
		}
	}
}
