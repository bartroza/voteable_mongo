module Mongoid
  module Voteable
    extend ActiveSupport::Concern

    # How many points should be assigned for each up or down vote.
    # This hash should manipulated using voteable method
    VOTEABLE = {}

    included do
      include Mongoid::Document
      include Mongoid::Voteable::Stats
      field :votes, :type => Mongoid::Voteable::Votes
      
      before_create do
        # Init votes so that counters and point have numeric values (0)
        self.votes = VOTES_DEFAULT_ATTRIBUTES
      end
      
      # Set vote point for each up (down) vote on an object of this class
      # 
      # @param [Hash] options a hash containings:
      # 
      # voteable self, :up => +1, :down => -3
      # voteable Post, :up => +2, :down => -1, :update_counters => false # skip counter update
      def self.voteable(klass = self, options = nil)
        VOTEABLE[self.name] ||= {}
        VOTEABLE[self.name][klass.name] ||= options
      end

      # We usually need to show current_user his voting value on voteable object
      # voting value can be nil (not voted yet), :up or :down
      # from voting value, we can decide it should be new vote or revote with :up or :down
      # In this case, validation can be skip to maximize performance

      # Make a vote on an object of this class
      #
      # @param [Hash] options a hash containings:
      #   - :votee_id: the votee document id
      #   - :voter_id: the voter document id
      #   - :value: :up or :down
      #   - :revote: change from vote up to vote down
      #   - :unvote: unvote the vote value (:up or :down)
      def self.vote(options)
        options.symbolize_keys!
        value = options[:value].to_sym
        
        votee_id = options[:votee_id]
        voter_id = options[:voter_id]
        
        votee_id = BSON::ObjectId(votee_id) if votee_id.is_a?(String)
        voter_id = BSON::ObjectId(voter_id) if voter_id.is_a?(String)

        klass = options[:class]
        klass ||= VOTEABLE.keys.include?(name) ? name : collection.name.classify
        value_point = VOTEABLE[klass][klass]
        
        if options[:revote]
          if value == :up
            positive_voter_ids = UP_VOTER_IDS
            negative_voter_ids = DOWN_VOTER_IDS
            positive_votes_count = UP_VOTES_COUNT
            negative_votes_count = DOWN_VOTES_COUNT
            point_delta = value_point[:up] - value_point[:down]
          else
            positive_voter_ids = DOWN_VOTER_IDS
            negative_voter_ids = UP_VOTER_IDS
            positive_votes_count = DOWN_VOTES_COUNT
            negative_votes_count = UP_VOTES_COUNT
            point_delta = -value_point[:up] + value_point[:down]
          end
          
          update_result = collection.update({ 
            # Validate voter_id did a vote with value for votee_id
            :_id => votee_id,
            positive_voter_ids => { '$ne' => voter_id },
            negative_voter_ids => voter_id
          }, {
            # then update
            '$pull' => { negative_voter_ids => voter_id },
            '$push' => { positive_voter_ids => voter_id },
            '$inc' => {
              positive_votes_count => +1,
              negative_votes_count => -1,
              VOTES_POINT => point_delta
            }
          }, {
            :safe => true
          })

        elsif options[:unvote]
          if value == :up
            positive_voter_ids = UP_VOTER_IDS
            negative_voter_ids = DOWN_VOTER_IDS
            positive_votes_count = UP_VOTES_COUNT
          else
            positive_voter_ids = DOWN_VOTER_IDS
            negative_voter_ids = UP_VOTER_IDS
            positive_votes_count = DOWN_VOTES_COUNT
          end
          
          # Check if voter_id did a vote with value for votee_id
          update_result = collection.update({ 
            # Validate voter_id did a vote with value for votee_id
            :_id => votee_id,
            negative_voter_ids => { '$ne' => voter_id },
            positive_voter_ids => voter_id
          }, {
            # then update
            '$pull' => { positive_voter_ids => voter_id },
            '$inc' => {
              positive_votes_count => -1,
              VOTES_COUNT => -1,
              VOTES_POINT => -value_point[value]
            }
          }, {
            :safe => true
          })
          
        else # new vote
          if value.to_sym == :up
            positive_voter_ids = UP_VOTER_IDS
            positive_votes_count = UP_VOTES_COUNT
          else
            positive_voter_ids = DOWN_VOTER_IDS
            positive_votes_count = DOWN_VOTES_COUNT
          end

          update_result = collection.update({ 
            # Validate voter_id did not vote for votee_id yet
            :_id => votee_id,
            UP_VOTER_IDS => { '$ne' => voter_id },
            DOWN_VOTER_IDS => { '$ne' => voter_id }
          }, {
            # then update
            '$push' => { positive_voter_ids => voter_id },
            '$inc' => {  
              VOTES_COUNT => +1,
              positive_votes_count => +1,
              VOTES_POINT => value_point[value] }
          }, {
            :safe => true
          })
        end
        
        # Only update parent class if votee is updated successfully
        successed = ( update_result['err'] == nil and 
          update_result['updatedExisting'] == true and
          update_result['n'] == 1 )

        if successed
          VOTEABLE[klass].each do |class_name, value_point|
            # For other class in VOTEABLE options, if is parent of current class
            next unless relation_metadata = relations[class_name.underscore]
            next unless votee ||= options[:votee] || find(options[:votee_id])
            # If can find current votee foreign_key value for that class
            next unless foreign_key_value = votee.read_attribute(relation_metadata.foreign_key)
          
            inc_options = {}
            
            if options[:revote]
              if value == :up
                inc_options[VOTES_POINT] = value_point[:up] - value_point[:down]
                unless value_point[:update_counters] == false
                  inc_options[UP_VOTES_COUNT] = +1
                  inc_options[DOWN_VOTES_COUNT] = -1
                end
              else
                inc_options[VOTES_POINT] = -value_point[:up] + value_point[:down]
                unless value_point[:update_counters] == false
                  inc_options[UP_VOTES_COUNT] = -1
                  inc_options[DOWN_VOTES_COUNT] = +1
                end
              end
            elsif options[:unvote]
              inc_options[VOTES_POINT] = -value_point[value]
              unless value_point[:update_counters] == false
                inc_options[VOTES_COUNT] = -1
                if value == :up
                  inc_options[UP_VOTES_COUNT] = -1
                else
                  inc_options[DOWN_VOTES_COUNT] = -1
                end
              end
            else # new vote
              inc_options[VOTES_POINT] = value_point[value]
              unless value_point[:update_counters] == false
                inc_options[VOTES_COUNT] = 1
                if value == :up
                  inc_options[UP_VOTES_COUNT] = 1
                else
                  inc_options[DOWN_VOTES_COUNT] = 1
                end
              end
            end
                    
            class_name.constantize.collection.update(
              { :_id => foreign_key_value }, 
              { '$inc' =>  inc_options }
            )
          end
        end
        true
      end
      
    end
  
    # Make a vote on this votee
    #
    # @param [Hash] options a hash containings:
    #   - :voter_id: the voter document id
    #   - :value: vote :up or vote :down
    def vote(options)
      options[:votee_id] ||= _id
      options[:votee] ||= self

      if options[:unvote]
        options[:value] ||= vote_value(options[:voter_id])
      else
        options[:revote] ||= !vote_value(options[:voter_id]).nil?
      end

      self.class.vote(options)
    end

    # Get a voted value on this votee
    #
    # @param [Mongoid Object, BSON::ObjectId] voter is Mongoid object the id of the voter who made the vote
    def vote_value(voter)
      voter_id = voter.is_a?(BSON::ObjectId) ? voter : voter._id
      return :up if up_voter_ids.include?(voter_id)
      return :down if down_voter_ids.include?(voter_id)
    end

    # Array of up voter ids
    def up_voter_ids
      votes.try(:[], 'u') || []
    end
    
    # Array of down voter ids
    def down_voter_ids
      votes.try(:[], 'd') || []
    end
  end
end
