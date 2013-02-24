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

#pragma once

#include "network_schema.h"
#include "network_data.h"
#include "layer_configuration_specific.h"
#include "supervised_data_reader.h"
#include "testing_result.h"
#include "data_scale_params.h"

#include <memory>

namespace nnforge
{
	class network_updater
	{
	public:
		virtual ~network_updater();

		// You don't need to call this method before calling get_hessian with supervised_data_reader_byte
		void set_input_configuration_specific(const layer_configuration_specific& input_configuration_specific);

		// Size of random_uniform_list is a power of 2
		std::vector<testing_result_smart_ptr> update(
			supervised_data_reader_byte& reader,
			const std::vector<network_data_smart_ptr>& training_speed_vector_list,
			std::vector<network_data_smart_ptr>& data_list,
			const std::map<unsigned int, float>& layer_to_dropout_rate_map,
			const std::vector<float>& random_uniform_list);

		// set_input_configuration_specific should be called prior to this method call for this method to succeed
		virtual unsigned int get_max_batch_size() const = 0;

		// set_input_configuration_specific should be called prior to this method call for this method to succeed
		float get_flops_for_single_entry() const;

		bool profile_mode;
		unsigned int entry_count_updated_in_profile_mode;

	protected:
		network_updater(
			network_schema_smart_ptr schema,
			const_data_scale_params_smart_ptr scale_params);

		// schema, data and reader are guaranteed to be compatible
		virtual std::vector<testing_result_smart_ptr> actual_update(
			supervised_data_reader_byte& reader,
			const std::vector<network_data_smart_ptr>& training_speed_vector_list,
			std::vector<network_data_smart_ptr>& data_list,
			const std::map<unsigned int, float>& layer_to_dropout_rate_map,
			const std::vector<float>& random_uniform_list) = 0;

		// The method is called when client calls set_input_configuration_specific and the convolution specific configuration is modified.
		// The layer_config_list is guaranteed to be compatible with schema
		virtual void layer_config_list_modified() = 0;

		void update_flops();

	protected:
		network_schema_smart_ptr schema;
		layer_configuration_specific_list layer_config_list;
		const_data_scale_params_smart_ptr current_scale_params; // Defined in set_input_configuration_specific
		float flops;

	private:
		network_updater();
		network_updater(const network_updater&);
		network_updater& operator =(const network_updater&);

		const_data_scale_params_smart_ptr scale_params;
	};

	typedef std::tr1::shared_ptr<network_updater> network_updater_smart_ptr;
}
