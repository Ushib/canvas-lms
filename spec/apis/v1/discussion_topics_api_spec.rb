#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../api_spec_helper')
require File.expand_path(File.dirname(__FILE__) + '/../locked_spec')

class TestCourseApi
  include Api
  include Api::V1::DiscussionTopics
  def feeds_topic_format_path(topic_id, code, format); "feeds_topic_format_path(#{topic_id.inspect}, #{code.inspect}, #{format.inspect})"; end
  def named_context_url(*args); "named_context_url(#{args.inspect[1..-2]})"; end
  def course_assignment_url(*args); "course_assignment_url(#{args.inspect[1..-2]})"; end
end

describe Api::V1::DiscussionTopics do
  before do
    @test_api = TestCourseApi.new
    course_with_teacher(:active_all => true, :user => user_with_pseudonym)
    @me = @user
    student_in_course(:active_all => true, :course => @course)
    @topic = @course.discussion_topics.create
  end

  it 'should render a podcast_url using the discussion topic\'s context if there is no @context_enrollment/@context' do
    @topic.update_attribute :podcast_enabled, true
    data = nil
    lambda {
      data = @test_api.discussion_topic_api_json(@topic, @topic.context, @me, {})
    }.should_not raise_error
    data[:podcast_url].should match /feeds_topic_format_path/
  end

  it "should set can_post_attachments" do
    data = @test_api.discussion_topic_api_json(@topic, @topic.context, @me, nil)
    data[:permissions][:attach].should == true # teachers can always attach

    data = @test_api.discussion_topic_api_json(@topic, @topic.context, @student, nil)
    data[:permissions][:attach].should == false # students can't attach by default

    @topic.context.update_attribute(:allow_student_forum_attachments, true)
    data = @test_api.discussion_topic_api_json(@topic, @topic.context, @student, nil)
    data[:permissions][:attach].should == true
  end

  it "should recognize include_assignment flag" do
    #set @domain_root_account
    @test_api.instance_variable_set(:@domain_root_account, Account.default)

    data = @test_api.discussion_topic_api_json(@topic, @topic.context, @me, nil)
    data[:assignment].should be_nil

    @topic.assignment = assignment_model(:course => @course)
    @topic.save!

    data = @test_api.discussion_topic_api_json(@topic, @topic.context, @me, nil, true)
    data[:assignment].should_not be_nil
  end
end

describe DiscussionTopicsController, :type => :integration do
  include Api::V1::User

  context 'locked api item' do
    let(:item_type) { 'discussion_topic' }

    let(:locked_item) do
      @course.discussion_topics.create!(:message => 'Locked Discussion')
    end

    def api_get_json
      api_call(
        :get,
        "/api/v1/courses/#{@course.id}/discussion_topics/#{locked_item.id}",
        {:controller => 'discussion_topics_api', :action => 'show', :format => 'json', :course_id => @course.id.to_s, :topic_id => locked_item.id.to_s},
      )
    end

    it_should_behave_like 'a locked api item'
  end

  before(:each) do
    course_with_teacher(:active_all => true, :user => user_with_pseudonym)
  end

  # needed for user_display_json
  def avatar_url_for_user(user, *a)
    "http://www.example.com/images/messages/avatar-50.png"
  end
  def blank_fallback
    nil
  end

  describe "user_display_json" do
    it "should return a html_url based on parent_context" do
      user_display_json(@user)[:html_url].should == "http://www.example.com/users/#{@user.id}"
      user_display_json(@user, nil)[:html_url].should == "http://www.example.com/users/#{@user.id}"
      user_display_json(@user, :profile)[:html_url].should == "http://www.example.com/about/#{@user.id}"
      user_display_json(@user, @course)[:html_url].should == "http://www.example.com/courses/#{@course.id}/users/#{@user.id}"
    end
  end

  context "create topic" do
    it "should check permissions" do
      @user = user(:active_all => true)
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "hai", :message => "test message" }, {}, :expected_status => 401)
    end

    it "should make a basic topic" do
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "test title", :message => "test <b>message</b>" })
      @topic = @course.discussion_topics.order(:id).last
      @topic.title.should == "test title"
      @topic.message.should == "test <b>message</b>"
      @topic.threaded?.should be_false
      @topic.published?.should be_true
      @topic.post_delayed?.should be_false
      @topic.podcast_enabled?.should be_false
      @topic.podcast_has_student_posts?.should be_false
      @topic.require_initial_post?.should be_false
    end

    it 'should process html content in message on create' do
      should_process_incoming_user_content(@course) do |content|
        api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
                 { :title => "test title", :message => content })

        @topic = @course.discussion_topics.order(:id).last
        @topic.message
      end
    end

    it "should post an announcment" do
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "test title", :message => "test <b>message</b>", :is_announcement => true, :published => true })
      @topic = @course.announcements.order(:id).last
      @topic.title.should == "test title"
      @topic.message.should == "test <b>message</b>"
    end

    it "should create a topic with all the bells and whistles" do
      post_at = 1.month.from_now
      lock_at = 2.months.from_now
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "test title", :message => "test <b>message</b>", :discussion_type => "threaded", 
                 :delayed_post_at => post_at.as_json, :lock_at => lock_at.as_json, :podcast_has_student_posts => '1', :require_initial_post => '1' })
      @topic = @course.discussion_topics.order(:id).last
      @topic.title.should == "test title"
      @topic.message.should == "test <b>message</b>"
      @topic.threaded?.should == true
      @topic.post_delayed?.should == true
      @topic.published?.should be_false
      @topic.delayed_post_at.to_i.should == post_at.to_i
      @topic.lock_at.to_i.should == lock_at.to_i
      @topic.podcast_enabled?.should == true
      @topic.podcast_has_student_posts?.should == true
      @topic.require_initial_post?.should == true
    end

    context "publishing" do
      it "should create a draft state topic" do
        api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
                 { :title => "test title", :message => "test <b>message</b>", :published => "false" })
        @topic = @course.discussion_topics.order(:id).last
        @topic.published?.should be_false
      end

      it "should not allow announcements to be draft state" do
        result = api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
                 { :title => "test title", :message => "test <b>message</b>", :published => "false", :is_announcement => true },
                 {}, {:expected_status => 400})
        result["errors"]["published"].should be_present
      end

      it "should require moderation permissions to create a draft state topic" do
        course_with_student_logged_in(:course => @course, :active_all => true)
        result = api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
                 { :title => "test title", :message => "test <b>message</b>", :published => "false" },
                 {}, {:expected_status => 400})
        result["errors"]["published"].should be_present
      end

      it "should allow non-moderators to set published" do
        course_with_student_logged_in(:course => @course, :active_all => true)
        api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
                 { :title => "test title", :message => "test <b>message</b>", :published => "true" })
        @topic = @course.discussion_topics.order(:id).last
        @topic.published?.should be_true
      end

    end

    it "should allow creating a discussion assignment" do
      due_date = 1.week.from_now
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "test title", :message => "test <b>message</b>", :assignment => { :points_possible => 15, :grading_type => "percent", :due_at => due_date.as_json, :name => "override!" } })
      @topic = @course.discussion_topics.order(:id).last
      @topic.title.should == "test title"
      @topic.assignment.should be_present
      @topic.assignment.points_possible.should == 15
      @topic.assignment.grading_type.should == "percent"
      @topic.assignment.due_at.to_i.should == due_date.to_i
      @topic.assignment.submission_types.should == "discussion_topic"
      @topic.assignment.title.should == "test title"
    end

    it "should not create an assignment on a discussion topic when set_assignment is false" do
      api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics",
               { :controller => "discussion_topics", :action => "create", :format => "json", :course_id => @course.to_param },
               { :title => "test title", :message => "test <b>message</b>", :assignment => { :set_assignment => 'false' } })
      @topic = @course.discussion_topics.order(:id).last
      @topic.title.should == "test title"
      @topic.assignment.should be_nil
    end
  end

  context "With item" do
    before do
      @attachment = create_attachment(@course)
      @topic = create_topic(@course, :title => "Topic 1", :message => "<p>content here</p>", :podcast_enabled => true, :attachment => @attachment)
      @sub = create_subtopic(@topic, :title => "Sub topic", :message => "<p>i'm subversive</p>")
      @response_json =
                 {"read_state"=>"read",
                  "unread_count"=>0,
                  "podcast_url"=>"/feeds/topics/#{@topic.id}/enrollment_randomness.rss",
                  "user_can_see_posts"=>@topic.user_can_see_posts?(@user),
                  "subscribed"=>@topic.subscribed?(@user),
                  "require_initial_post"=>nil,
                  "title"=>"Topic 1",
                  "discussion_subentry_count"=>0,
                  "assignment_id"=>nil,
                  "published"=>true,
                  "delayed_post_at"=>nil,
                  "lock_at"=>nil,
                  "id"=>@topic.id,
                  "user_name"=>@user.name,
                  "last_reply_at"=>@topic.last_reply_at.as_json,
                  "message"=>"<p>content here</p>",
                  "posted_at"=>@topic.posted_at.as_json,
                  "root_topic_id"=>nil,
                  "pinned"=>false,
                  "position"=>@topic.position,
                  "url" => "http://www.example.com/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                  "html_url" => "http://www.example.com/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                  "podcast_has_student_posts" => nil,
                  "attachments"=>[{"content-type"=>"unknown/unknown",
                                   "url"=>"http://www.example.com/files/#{@attachment.id}/download?download_frd=1&verifier=#{@attachment.uuid}",
                                   "filename"=>"content.txt",
                                   "display_name"=>"content.txt",
                                   "id"=>@attachment.id,
                                   "size"=>@attachment.size,
                                   'unlock_at' => nil,
                                   'locked' => false,
                                   'hidden' => false,
                                   'lock_at' => nil,
                                   'locked_for_user' => false,
                                   'hidden_for_user' => false,
                                   'created_at' => @attachment.created_at.as_json,
                                   'updated_at' => @attachment.updated_at.as_json,
                                   'thumbnail_url' => @attachment.thumbnail_url,
                  }],
                  "topic_children"=>[@sub.id],
                  "discussion_type" => 'side_comment',
                  "locked"=>false,
                  "locked_for_user"=>false,
                  "author" => user_display_json(@topic.user, @topic.context).stringify_keys!,
                  "permissions" => { "delete"=>true, "attach"=>true, "update"=>true }}
    end

    describe "GET 'index'" do
      it "should return discussion topic list" do
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s})

        json.size.should == 2
        # get rid of random characters in podcast url
        json.last["podcast_url"].gsub!(/_[^.]*/, '_randomness')
        json.last.should == @response_json.merge("subscribed" => @sub.subscribed?(@user))
      end

      it "should search discussion topics by title" do
        ids = @course.discussion_topics.map(&:id)
        create_topic(@course, :title => "ignore me", :message => "<p>i'm subversive</p>")
        create_topic(@course, :title => "ignore me2", :message => "<p>i'm subversive</p>")
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?search_term=topic",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s,
                         :search_term => 'topic'})

        json.map{|h| h['id']}.sort.should == ids.sort
      end

      it "should order topics by descending position by default" do
        @topic2 = create_topic(@course, :title => "Topic 2", :message => "<p>content here</p>")
        @topic3 = create_topic(@course, :title => "Topic 3", :message => "<p>content here</p>")
        topics = [@topic3, @topic, @topic2, @sub]
        topics.reverse.each_with_index do |topic, index|
          topic.position = index + 1
          topic.save!
        end

        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s})
        json.map {|j| j['id']}.should == topics.map(&:id)
      end

      it "should order topics by descending last_reply_at when order_by parameter is specified" do
        @topic2 = create_topic(@course, :title => "Topic 2", :message => "<p>content here</p>")
        @topic3 = create_topic(@course, :title => "Topic 3", :message => "<p>content here</p>")

        topics = [@topic3, @topic, @topic2, @sub]
        topic_reply_date = Time.zone.now - 1.day
        topics.each do |topic|
          topic.last_reply_at = topic_reply_date
          topic.save!
          topic_reply_date -= 1.day
        end

        # topic that hasn't had a reply yet should be at the top
        @topic4 = create_topic(@course, :title => "Topic 4", :message => "<p>content here</p>")
        topics.unshift(@topic4)
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?order_by=recent_activity",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s, :order_by => 'recent_activity'})
        json.map {|j| j['id']}.should == topics.map(&:id)
      end

      it "should only include topics with a given scope when specified" do
        @topic2 = create_topic(@course, :title => "Topic 2", :message => "<p>content here</p>")
        @topic3 = create_topic(@course, :title => "Topic 3", :message => "<p>content here</p>")
        [@topic, @sub, @topic2, @topic3].each do |topic|
          topic.save!
        end
        [@sub, @topic2, @topic3].each(&:lock!)
        
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?per_page=10&scope=unlocked",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s, 
                          :per_page => '10', :scope => 'unlocked'})
        json.size.should == 1
        links = response.headers['Link'].split(',')
        links.each do |link|
          link.should match('scope=unlocked')
        end

        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?per_page=10&scope=locked",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s, 
                          :per_page => '10', :scope => 'locked'})
        json.size.should == 3
        links = response.headers['Link'].split(',')
        links.each do |link|
          link.should match('scope=locked')
        end
      end
      
      it "should include all parameters in pagination urls" do
        @topic2 = create_topic(@course, :title => "Topic 2", :message => "<p>content here</p>")
        @topic3 = create_topic(@course, :title => "Topic 3", :message => "<p>content here</p>")
        [@topic, @sub, @topic2, @topic3].each do |topic|
          topic.type = 'Announcement'
          topic.save!
        end
        
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?per_page=2&only_announcements=true&order_by=recent_activity&scope=unlocked",
                        {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s,
                          :per_page => '2', :order_by => 'recent_activity', :only_announcements => 'true', :scope => 'unlocked'})
        json.size.should == 2
        links = response.headers['Link'].split(',')
        links.each do |link|
          link.should match('only_announcements=true')
          link.should match('order_by=recent_activity')
          link.should match('scope=unlocked')
        end
      end
    end

    describe "GET 'show'" do
      it "should return an individual topic" do
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                        {:controller => 'discussion_topics_api', :action => 'show', :format => 'json', :course_id => @course.id.to_s, :topic_id => @topic.id.to_s})

        # get rid of random characters in podcast url
        json["podcast_url"].gsub!(/_[^.]*/, '_randomness')
        json.should == @response_json.merge("subscribed" => @topic.subscribed?(@user))
      end
    end

    describe "PUT 'update'" do
      it "should require authorization" do
        @user = user(:active_all => true)
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :title => "hai", :message => "test message" }, {}, :expected_status => 401)
      end

      it "should update the entry" do
        post_at = 1.month.from_now
        lock_at = 2.months.from_now
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :title => "test title",
                   :message => "test <b>message</b>",
                   :discussion_type => "threaded",
                   :delayed_post_at => post_at.as_json,
                   :lock_at => lock_at.as_json,
                   :podcast_has_student_posts => '1',
                   :require_initial_post => '1' })
        @topic.reload
        @topic.title.should == "test title"
        @topic.message.should == "test <b>message</b>"
        @topic.threaded?.should == true
        @topic.post_delayed?.should == true
        @topic.delayed_post_at.to_i.should == post_at.to_i
        @topic.lock_at.to_i.should == lock_at.to_i
        @topic.podcast_enabled?.should == true
        @topic.podcast_has_student_posts?.should == true
        @topic.require_initial_post?.should == true
      end

      it "should not unlock topic if lock_at changes but is still in the past" do
        lock_at = 1.month.ago
        new_lock_at = 1.week.ago
        @topic.workflow_state = 'active'
        @topic.locked = true
        @topic.lock_at = lock_at
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :lock_at => new_lock_at.as_json })
        @topic.reload
        @topic.lock_at.to_i.should == new_lock_at.to_i
        @topic.should be_locked
      end

      it "should update workflow_state if delayed_post_at changed to future" do
        post_at = 1.month.from_now
        @topic.workflow_state = 'active'
        @topic.locked = true
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :delayed_post_at => post_at.as_json })
        @topic.reload
        @topic.delayed_post_at.to_i.should == post_at.to_i
        @topic.should be_post_delayed
      end

      it "should not change workflow_state if lock_at does not change" do
        lock_at = 1.month.from_now.change(:usec => 0)
        @topic.lock_at = lock_at
        @topic.workflow_state = 'active'
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :lock_at => lock_at.as_json })

        @topic.reload
        @topic.lock_at.should == lock_at
        @topic.should be_active
      end

      it "should unlock topic if lock_at is changed to future" do
        old_lock_at = 1.month.ago
        new_lock_at = 1.month.from_now
        @topic.lock_at = old_lock_at
        @topic.workflow_state = 'active'
        @topic.locked = true
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :lock_at => new_lock_at.as_json })

        @topic.reload
        @topic.lock_at.to_i.should == new_lock_at.to_i
        @topic.should be_active
        @topic.should_not be_locked
      end

      it "should lock the topic if lock_at is changed to the past" do
        old_lock_at = 1.month.from_now
        new_lock_at = 1.month.ago
        @topic.lock_at = old_lock_at
        @topic.workflow_state = 'active'
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :lock_at => new_lock_at.as_json })

        @topic.reload
        @topic.lock_at.to_i.should == new_lock_at.to_i
        @topic.should be_locked
      end

      it "should not lock the topic if lock_at is cleared" do
        @topic.lock_at = 1.month.ago
        @topic.workflow_state = 'active'
        @topic.save!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :lock_at => '' })

        @topic.reload
        @topic.lock_at.should be_nil
        @topic.should be_active
        @topic.should_not be_locked
      end

      context "publishing" do
        it "should publish a draft state topic" do
          @topic.workflow_state = 'post_delayed'
          @topic.save!
          @topic.should_not be_published
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "true"})
          @topic.reload.should be_published
        end

        it "should not allow announcements to be draft state" do
          @topic.type = 'Announcement'
          @topic.save!
          result = api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "false" },
                   {}, {:expected_status => 400})
          result["errors"]["published"].should be_present
        end


        it "should allow a topic with no posts to set draft state" do
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "false"})
          @topic.reload.should_not be_published
        end

        it "should prevent a topic with posts from setting draft state" do
          create_entry(@topic)
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "false"}, {}, {:expected_status => 400})
          @topic.reload.should be_published
        end

        it "should require moderation permissions to set draft state" do
          course_with_student_logged_in(:course => @course, :active_all => true)
          @topic = create_topic(@course, :user => @student)
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "false"}, {}, {:expected_status => 400})
          @topic.reload.should be_published
        end

        it "should allow non-moderators to set published" do
          course_with_student_logged_in(:course => @course, :active_all => true)
          @topic = create_topic(@course, :user => @student)
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :published => "true"})
          @topic.reload.should be_published
        end
      end

      it 'should process html content in message on update' do
        should_process_incoming_user_content(@course) do |content|
          api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                   { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                   { :message => content })

          @topic.reload
          @topic.message
        end
      end

      it "should set the editor_id to whoever edited to entry" do
        @original_user = @user
        @editing_user = user_model
        @course.enroll_teacher(@editing_user).accept

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :title => "edited by someone else"})
        @topic.reload
        @topic.editor.should eql(@editing_user)
        @topic.user.should eql(@original_user)
      end

      it "should not drift when saving delayed_post_at with user-preferred timezone set" do
        @user.time_zone = 'Alaska'
        @user.save

        user_tz = Time.use_zone(@user.time_zone) { Time.zone }
        expected_time = user_tz.parse("Fri Aug 26, 2031 8:39AM")

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :delayed_post_at => expected_time.as_json})

        @topic.reload
        @topic.delayed_post_at.should == expected_time
      end

      it "should allow creating assignment on update" do
        due_date = 1.week.ago
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :assignment => { :points_possible => 15, :grading_type => "percent", :due_at => due_date.as_json, :name => "override!" } })
        @topic.reload

        @topic.title.should == "Topic 1"
        @topic.assignment.should be_present
        @topic.assignment.points_possible.should == 15
        @topic.assignment.grading_type.should == "percent"
        @topic.assignment.due_at.to_i.should == due_date.to_i
        @topic.assignment.submission_types.should == "discussion_topic"
        @topic.assignment.title.should == "Topic 1"
      end

      it "should allow removing assignment on update" do
        @assignment = @topic.context.assignments.build
        @topic.assignment = @assignment
        @topic.save!
        @topic.assignment.should be_present

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :assignment => { :set_assignment => false } })
        @topic.reload
        @assignment.reload

        @topic.title.should == "Topic 1"
        @topic.assignment.should be_nil
        @topic.old_assignment_id.should == @assignment.id
        @assignment.should be_deleted
      end

      it "should allow pinning a topic" do
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { controller: 'discussion_topics', action: 'update', format: 'json', course_id: @course.to_param, topic_id: @topic.to_param },
                 { pinned: true })
        @topic.reload.should be_pinned
      end

      it "should allow unpinning a topic" do
        @topic.update_attribute(:pinned, true)
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { controller: 'discussion_topics', action: 'update', format: 'json', course_id: @course.to_param, topic_id: @topic.to_param },
                 { pinned: false })
        @topic.reload.should_not be_pinned
      end

      it "should allow unlocking a locked topic" do
        @topic.lock!

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :locked => false})

        @topic.reload
        @topic.should_not be_locked
      end

      it "should allow locking a topic after due date" do
        due_date = 1.week.ago
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :assignment => { :due_at => due_date.as_json } })
        @topic.reload
        @topic.assignment.due_at.to_i.should == due_date.to_i

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :locked => true})

        @topic.reload
        @topic.should be_locked

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :locked => false})

        @topic.reload
        @topic.should_not be_locked
      end

      it "should not allow locking a topic before due date" do
        due_date = 1.week.from_now
        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :assignment => { :due_at => due_date.as_json } })
        @topic.reload
        @topic.assignment.due_at.to_i.should == due_date.to_i

        api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "update", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 { :locked => true}, {}, :expected_status => 500)

        @topic.reload
        @topic.should_not be_locked
      end
    end

    describe "DELETE 'destroy'" do
      it "should require authorization" do
        @user = user(:active_all => true)
        api_call(:delete, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "destroy", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param },
                 {}, {}, :expected_status => 401)
        @topic.reload.should_not be_deleted
      end

      it "should delete the topic" do
        api_call(:delete, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}",
                 { :controller => "discussion_topics", :action => "destroy", :format => "json", :course_id => @course.to_param, :topic_id => @topic.to_param })
        @topic.reload.should be_deleted
      end
    end
  end

  it "should translate user content in topics" do
    should_translate_user_content(@course) do |user_content|
      @topic = create_topic(@course, :title => "Topic 1", :message => user_content)
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics",
        { :controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s })
      json.size.should == 1
      json.first['message']
    end
  end

  it "should paginate and return proper pagination headers for courses" do
    7.times { |i| @course.discussion_topics.create!(:title => i.to_s, :message => i.to_s) }
    @course.discussion_topics.count.should == 7
    json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?per_page=3",
                    {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s, :per_page => '3'})

    json.length.should == 3
    links = response.headers['Link'].split(",")
    links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics/ }.should be_true
    links.find{ |l| l.match(/rel="next"/)}.should =~ /page=2&per_page=3>/
    links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
    links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/

    # get the last page
    json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json?page=3&per_page=3",
                    {:controller => 'discussion_topics', :action => 'index', :format => 'json', :course_id => @course.id.to_s, :page => '3', :per_page => '3'})
    json.length.should == 1
    links = response.headers['Link'].split(",")
    links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics/ }.should be_true
    links.find{ |l| l.match(/rel="prev"/)}.should =~ /page=2&per_page=3>/
    links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
    links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/
  end

  it "should work with groups" do
    group_category = @course.group_categories.create(:name => 'watup')
    group = group_category.groups.create!(:name => "group1", :context => @course)
    group.add_user(@user)
    attachment = create_attachment(group)
    gtopic = create_topic(group, :title => "Group Topic 1", :message => "<p>content here</p>", :attachment => attachment)

    json = api_call(:get, "/api/v1/groups/#{group.id}/discussion_topics.json",
                    {:controller => 'discussion_topics', :action => 'index', :format => 'json', :group_id => group.id.to_s}).first
    expected = {
      "read_state"=>"read",
      "unread_count"=>0,
      "user_can_see_posts"=>true,
      "subscribed"=>true,
      "podcast_url"=>nil,
      "podcast_has_student_posts"=>nil,
      "require_initial_post"=>nil,
      "title"=>"Group Topic 1",
      "discussion_subentry_count"=>0,
      "assignment_id"=>nil,
      "published"=>true,
      "delayed_post_at"=>nil,
      "lock_at"=>nil,
      "id"=>gtopic.id,
      "user_name"=>@user.name,
      "last_reply_at"=>gtopic.last_reply_at.as_json,
      "message"=>"<p>content here</p>",
      "pinned"=>false,
      "position"=>gtopic.position,
      "url" => "http://www.example.com/groups/#{group.id}/discussion_topics/#{gtopic.id}",
      "html_url" => "http://www.example.com/groups/#{group.id}/discussion_topics/#{gtopic.id}",
      "attachments"=>
              [{"content-type"=>"unknown/unknown",
                "url"=>"http://www.example.com/files/#{attachment.id}/download?download_frd=1&verifier=#{attachment.uuid}",
                "filename"=>"content.txt",
                "display_name"=>"content.txt",
                "id" => attachment.id,
                "size" => attachment.size,
                'unlock_at' => nil,
                'locked' => false,
                'hidden' => false,
                'lock_at' => nil,
                'locked_for_user' => false,
                'hidden_for_user' => false,
                'created_at' => attachment.created_at.as_json,
                'updated_at' => attachment.updated_at.as_json,
                'thumbnail_url' => attachment.thumbnail_url,
              }],
      "posted_at"=>gtopic.posted_at.as_json,
      "root_topic_id"=>nil,
      "topic_children"=>[],
      "discussion_type" => 'side_comment',
      "permissions" => {"delete"=>true, "attach"=>true, "update"=>true},
      "locked" => false,
      "locked_for_user" => false,
      "author" => user_display_json(gtopic.user, gtopic.context).stringify_keys!
    }
    json.should == expected
  end

  it "should paginate and return proper pagination headers for groups" do
    group_category = @course.group_categories.create(:name => "watup")
    group = group_category.groups.create!(:name => "group1", :context => @course)
    7.times { |i| create_topic(group, :title => i.to_s, :message => i.to_s) }
    group.discussion_topics.count.should == 7
    json = api_call(:get, "/api/v1/groups/#{group.id}/discussion_topics.json?per_page=3",
                    {:controller => 'discussion_topics', :action => 'index', :format => 'json', :group_id => group.id.to_s, :per_page => '3'})

    json.length.should == 3
    links = response.headers['Link'].split(",")
    links.all?{ |l| l =~ /api\/v1\/groups\/#{group.id}\/discussion_topics/ }.should be_true
    links.find{ |l| l.match(/rel="next"/)}.should =~ /page=2&per_page=3>/
    links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
    links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/

      # get the last page
    json = api_call(:get, "/api/v1/groups/#{group.id}/discussion_topics.json?page=3&per_page=3",
                    {:controller => 'discussion_topics', :action => 'index', :format => 'json', :group_id => group.id.to_s, :page => '3', :per_page => '3'})
    json.length.should == 1
    links = response.headers['Link'].split(",")
    links.all?{ |l| l =~ /api\/v1\/groups\/#{group.id}\/discussion_topics/ }.should be_true
    links.find{ |l| l.match(/rel="prev"/)}.should =~ /page=2&per_page=3>/
    links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
    links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/
  end

  it "should fulfill module viewed requirements when marking a topic read" do
    @module = @course.context_modules.create!(:name => "some module")
    @topic = create_topic(@course, :title => "Topic 1", :message => "<p>content here</p>")
    tag = @module.add_item(:id => @topic.id, :type => 'discussion_topic')
    @module.completion_requirements = { tag.id => {:type => 'must_view'} }
    @module.save!
    course_with_student(:course => @course)

    @module.evaluate_for(@user, true).should be_unlocked
    raw_api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/read",
                 { :controller => 'discussion_topics_api', :action => 'mark_topic_read', :format => 'json',
                   :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
    @module.evaluate_for(@user).should be_completed
  end

  it "should fulfill module viewed requirements when re-marking a topic read" do
    @module = @course.context_modules.create!(:name => "some module")
    @topic = create_topic(@course, :title => "Topic 1", :message => "<p>content here</p>")
    course_with_student(:course => @course)
    raw_api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/read",
                 { :controller => 'discussion_topics_api', :action => 'mark_topic_read', :format => 'json',
                   :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })

    tag = @module.add_item(:id => @topic.id, :type => 'discussion_topic')
    @module.completion_requirements = { tag.id => {:type => 'must_view'} }
    @module.save!

    @module.evaluate_for(@user, true).should be_unlocked
    raw_api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/read",
                 { :controller => 'discussion_topics_api', :action => 'mark_topic_read', :format => 'json',
                   :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
    @module.evaluate_for(@user).should be_completed
  end

  it "should fulfill module viewed requirements when marking a topic and all its entries read" do
    @module = @course.context_modules.create!(:name => "some module")
    @topic = create_topic(@course, :title => "Topic 1", :message => "<p>content here</p>")
    tag = @module.add_item(:id => @topic.id, :type => 'discussion_topic')
    @module.completion_requirements = { tag.id => {:type => 'must_view'} }
    @module.save!
    course_with_student(:course => @course)

    @module.evaluate_for(@user, true).should be_unlocked
    raw_api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/read_all",
                 { :controller => 'discussion_topics_api', :action => 'mark_all_read', :format => 'json',
                   :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
    @module.evaluate_for(@user).should be_completed
  end

  context "creating an entry under a topic" do
    before :each do
      @topic = create_topic(@course, :title => "Topic 1", :message => "<p>content here</p>")
      @message = "my message"
    end

    it "should allow creating an entry under a topic and create it correctly" do
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
        { :message => @message })
      json.should_not be_nil
      json['id'].should_not be_nil
      @entry = DiscussionEntry.find_by_id(json['id'])
      @entry.should_not be_nil
      @entry.discussion_topic.should == @topic
      @entry.user.should == @user
      @entry.parent_entry.should be_nil
      @entry.message.should == @message
    end

    it "should return json representation of the new entry" do
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
        { :message => @message })
      @entry = DiscussionEntry.find_by_id(json['id'])
      json.should == {
        "id" => @entry.id,
        "parent_id" => @entry.parent_id,
        "user_id" => @user.id,
        "user_name" => @user.name,
        "read_state" => "read",
        "forced_read_state" => false,
        "message" => @message,
        "created_at" => @entry.created_at.utc.iso8601,
        "updated_at" => @entry.updated_at.as_json,
      }
    end

    it "should allow creating a reply to an existing top-level entry" do
      top_entry = create_entry(@topic, :message => 'top-level message')
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{top_entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'add_reply', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => top_entry.id.to_s },
        { :message => @message })
      @entry = DiscussionEntry.find_by_id(json['id'])
      @entry.parent_entry.should == top_entry
    end

    it "should allow including attachments on top-level entries" do
      data = ActionController::TestUploadedFile.new(File.join(File.dirname(__FILE__), "/../../fixtures/scribd_docs/txt.txt"), "text/plain", true)
      require 'action_controller'
      require 'action_controller/test_process.rb'
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
        { :message => @message, :attachment => data })
      @entry = DiscussionEntry.find_by_id(json['id'])
      @entry.attachment.should_not be_nil
    end

    it "should include attachments on replies to top-level entries" do
      top_entry = create_entry(@topic, :message => 'top-level message')
      require 'action_controller'
      require 'action_controller/test_process.rb'
      data = ActionController::TestUploadedFile.new(File.join(File.dirname(__FILE__), "/../../fixtures/scribd_docs/txt.txt"), "text/plain", true)
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{top_entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'add_reply', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => top_entry.id.to_s },
        { :message => @message, :attachment => data })
      @entry = DiscussionEntry.find_by_id(json['id'])
      @entry.attachment.should_not be_nil
    end

    it "should include attachment info in the json response" do
      data = ActionController::TestUploadedFile.new(File.join(File.dirname(__FILE__), "/../../fixtures/scribd_docs/txt.txt"), "text/plain", true)
      require 'action_controller'
      require 'action_controller/test_process.rb'
      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
        { :message => @message, :attachment => data })
      json['attachment'].should_not be_nil
      json['attachment'].should_not be_empty
    end

    it "should create a submission from an entry on a graded topic" do
      @topic.assignment = assignment_model(:course => @course)
      @topic.save

      student_in_course(:active_all => true)
      @user.submissions.should be_empty

      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
        { :message => @message })

      @user.reload
      @user.submissions.size.should == 1
      @user.submissions.first.submission_type.should == 'discussion_topic'
    end

    it "should create a submission from a reply on a graded topic" do
      top_entry = create_entry(@topic, :message => 'top-level message')

      @topic.assignment = assignment_model(:course => @course)
      @topic.save

      student_in_course(:active_all => true)
      @user.submissions.should be_empty

      json = api_call(
        :post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{top_entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'add_reply', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => top_entry.id.to_s },
        { :message => @message })

      @user.reload
      @user.submissions.size.should == 1
      @user.submissions.first.submission_type.should == 'discussion_topic'
    end
  end

  context "listing top-level discussion entries" do
    before :each do
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      @attachment = create_attachment(@course)
      @entry = create_entry(@topic, :message => "first top-level entry", :attachment => @attachment)
      @reply = create_reply(@entry, :message => "reply to first top-level entry")
    end

    it "should return top level entries for a topic" do
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.size.should == 1
      entry_json = json.first
      entry_json['id'].should == @entry.id
    end

    it "should return attachments on top level entries" do
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      entry_json = json.first
      entry_json['attachment'].should_not be_nil
      entry_json['attachment']['url'].should == "http://#{Account.default.domain}/files/#{@attachment.id}/download?download_frd=1&verifier=#{@attachment.uuid}"
    end

    it "should include replies on top level entries" do
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      entry_json = json.first
      entry_json['recent_replies'].size.should == 1
      entry_json['has_more_replies'].should be_false
      reply_json = entry_json['recent_replies'].first
      reply_json['id'].should == @reply.id
    end

    it "should sort top-level entries by descending created_at" do
      @older_entry = create_entry(@topic, :message => "older top-level entry", :created_at => Time.now - 1.minute)
      @newer_entry = create_entry(@topic, :message => "newer top-level entry", :created_at => Time.now + 1.minute)
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.size.should == 3
      json.first['id'].should == @newer_entry.id
      json.last['id'].should == @older_entry.id
    end

    it "should sort replies included on top-level entries by descending created_at" do
      @older_reply = create_reply(@entry, :message => "older reply", :created_at => Time.now - 1.minute)
      @newer_reply = create_reply(@entry, :message => "newer reply", :created_at => Time.now + 1.minute)
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.size.should == 1
      reply_json = json.first['recent_replies']
      reply_json.size.should == 3
      reply_json.first['id'].should == @newer_reply.id
      reply_json.last['id'].should == @older_reply.id
    end

    it "should paginate top-level entries" do
      # put in lots of entries
      entries = []
      7.times{ |i| entries << create_entry(@topic, :message => i.to_s, :created_at => Time.now + (i+1).minutes) }

      # first page
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json?per_page=3",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :per_page => '3' })
      json.length.should == 3
      json.map{ |e| e['id'] }.should == entries.last(3).reverse.map{ |e| e.id }
      links = response.headers['Link'].split(",")
      links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics\/#{@topic.id}\/entries/ }.should be_true
      links.find{ |l| l.match(/rel="next"/)}.should =~ /page=2&per_page=3>/
      links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
      links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/

      # last page
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json?page=3&per_page=3",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :page => '3', :per_page => '3' })
      json.length.should == 2
      json.map{ |e| e['id'] }.should == [entries.first, @entry].map{ |e| e.id }
      links = response.headers['Link'].split(",")
      links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics\/#{@topic.id}\/entries/ }.should be_true
      links.find{ |l| l.match(/rel="prev"/)}.should =~ /page=2&per_page=3>/
      links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
      links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/
    end

    it "should only include the first 10 replies for each top-level entry" do
      # put in lots of replies
      replies = []
      12.times{ |i| replies << create_reply(@entry, :message => i.to_s, :created_at => Time.now + (i+1).minutes) }

      # get entry
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.length.should == 1
      reply_json = json.first['recent_replies']
      reply_json.length.should == 10
      reply_json.map{ |e| e['id'] }.should == replies.last(10).reverse.map{ |e| e.id }
      json.first['has_more_replies'].should be_true
    end
  end

  context "listing replies" do
    before :each do
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      @entry = create_entry(@topic, :message => "top-level entry")
      @reply = create_reply(@entry, :message => "first reply")
    end

    it "should return replies for an entry" do
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
      json.size.should == 1
      json.first['id'].should == @reply.id
    end

    it "should translate user content in replies" do
      should_translate_user_content(@course) do |user_content|
        @reply.update_attribute('message', user_content)
        json = api_call(
          :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json",
          { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
            :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
        json.size.should == 1
        json.first['message']
      end
    end

    it "should sort replies by descending created_at" do
      @older_reply = create_reply(@entry, :message => "older reply", :created_at => Time.now - 1.minute)
      @newer_reply = create_reply(@entry, :message => "newer reply", :created_at => Time.now + 1.minute)
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
      json.size.should == 3
      json.first['id'].should == @newer_reply.id
      json.last['id'].should == @older_reply.id
    end

    it "should paginate replies" do
      # put in lots of replies
      replies = []
      7.times{ |i| replies << create_reply(@entry, :message => i.to_s, :created_at => Time.now + (i+1).minutes) }

      # first page
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json?per_page=3",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s, :per_page => '3' })
      json.length.should == 3
      json.map{ |e| e['id'] }.should == replies.last(3).reverse.map{ |e| e.id }
      links = response.headers['Link'].split(",")
      links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics\/#{@topic.id}\/entries\/#{@entry.id}\/replies/ }.should be_true
      links.find{ |l| l.match(/rel="next"/)}.should =~ /page=2&per_page=3>/
      links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
      links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/

      # last page
      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json?page=3&per_page=3",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s, :page => '3', :per_page => '3' })
      json.length.should == 2
      json.map{ |e| e['id'] }.should == [replies.first, @reply].map{ |e| e.id }
      links = response.headers['Link'].split(",")
      links.all?{ |l| l =~ /api\/v1\/courses\/#{@course.id}\/discussion_topics\/#{@topic.id}\/entries\/#{@entry.id}\/replies/ }.should be_true
      links.find{ |l| l.match(/rel="prev"/)}.should =~ /page=2&per_page=3>/
      links.find{ |l| l.match(/rel="first"/)}.should =~ /page=1&per_page=3>/
      links.find{ |l| l.match(/rel="last"/)}.should =~ /page=3&per_page=3>/
    end
  end

  # stolen and adjusted from spec/controllers/discussion_topics_controller_spec.rb
  context "require initial post" do
    before(:each) do
      course_with_student(:active_all => true)

      @observer = user(:name => "Observer", :active_all => true)
      e = @course.enroll_user(@observer, 'ObserverEnrollment')
      e.associated_user = @student
      e.save
      @observer.reload

      course_with_teacher(:course => @course, :active_all => true)
      @context = @course
      discussion_topic_model
      @topic.require_initial_post = true
      @topic.save
    end

    describe "teacher" do
      before(:each) do
        @user = @teacher
        @url  = "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries"
      end

      it "should see topic entries without posting" do
        @topic.reply_from(user: @student, text: 'hai')
        json = api_call(:get, @url, controller: 'discussion_topics_api',
          action: 'entries', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)

        json.length.should == 1
      end
    end

    describe "student" do
      before(:each) do
        @topic.reply_from(user: @teacher, text: 'Lorem ipsum dolor')
        @user = @student
        @url  = "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}"
      end

      it "should see topic information before posting" do
        json = api_call(:get, @url, controller: 'discussion_topics_api',
          action: 'show', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)
        response.code.should == '200'
      end

      it "should not see entries before posting" do
        raw_api_call(:get, "#{@url}/entries", controller: 'discussion_topics_api',
          action: 'entries', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)
        response.body.should == 'require_initial_post'
        response.code.should == '403'
      end

      it "should see entries after posting" do
        @topic.reply_from(:user => @student, :text => 'hai')
        json = api_call(:get, "#{@url}/entries", controller: 'discussion_topics_api',
          action: 'entries', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)
        response.code.should == '200'
      end
    end

    describe "observer" do
      before(:each) do
        @topic.reply_from(user: @teacher, text: 'Lorem ipsum')
        @user = @observer
        @url  = "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries"
      end

      it "should not see entries before posting" do
        raw_api_call(:get, @url, controller: 'discussion_topics_api',
          action: 'entries', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)
        response.body.should == 'require_initial_post'
        response.code.should == '403'
      end

      it "should see entries after posting" do
        @topic.reply_from(user: @student, text: 'Lorem ipsum dolor')
        json = api_call(:get, @url, controller: 'discussion_topics_api',
          action: 'entries', format: 'json', course_id: @course.to_param,
          topic_id: @topic.to_param)
        response.code.should == '200'
      end
    end
  end

  context "update entry" do
    before do
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      @entry = create_entry(@topic, :message => "<p>top-level entry</p>")
    end

    it "should 401 if the user can't update" do
      student_in_course(:course => @course, :user => user_with_pseudonym)
      api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "update", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, { :message => 'haxor' }, {}, :expected_status => 401)
      @entry.reload.message.should == '<p>top-level entry</p>'
    end

    it "should 404 if the entry is deleted" do
      @entry.destroy
      api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "update", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, { :message => 'haxor' }, {}, :expected_status => 404)
    end

    it "should update the message" do
      api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "update", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, { :message => '<p>i had a spleling error</p>' })
      @entry.reload.message.should == '<p>i had a spleling error</p>'
    end

    it "should allow passing an plaintext message (undocumented)" do
      # undocumented but used by the dashboard right now (this'll go away eventually)
      api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "update", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, { :plaintext_message => 'i had a spleling error' })
      @entry.reload.message.should == 'i had a spleling error'
    end

    it "should allow teachers to edit student entries" do
      @teacher = @user
      student_in_course(:course => @course, :user => user_with_pseudonym)
      @student = @user
      @user = @teacher
      @entry = create_entry(@topic, :message => 'i am a student', :user => @student)
      @entry.user.should == @student
      @entry.editor.should be_nil

      api_call(:put, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "update", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, { :message => '<p>denied</p>' })
      @entry.reload.message.should == '<p>denied</p>'
      @entry.editor.should == @teacher
    end
  end

  context "delete entry" do
    before do
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      @entry = create_entry(@topic, :message => "top-level entry")
    end

    it "should 401 if the user can't delete" do
      student_in_course(:course => @course, :user => user_with_pseudonym)
      api_call(:delete, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "destroy", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, {}, {}, :expected_status => 401)
      @entry.reload.should_not be_deleted
    end

    it "should soft-delete the entry" do
      raw_api_call(:delete, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "destroy", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, {}, {}, :expected_status => 204)
      response.body.should be_blank
      @entry.reload.should be_deleted
    end

    it "should allow teachers to delete student entries" do
      @teacher = @user
      student_in_course(:course => @course, :user => user_with_pseudonym)
      @student = @user
      @user = @teacher
      @entry = create_entry(@topic, :message => 'i am a student', :user => @student)
      @entry.user.should == @student
      @entry.editor.should be_nil

      raw_api_call(:delete, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}",
               { :controller => "discussion_entries", :action => "destroy", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :id => @entry.id.to_s }, {}, {}, :expected_status => 204)
      @entry.reload.should be_deleted
      @entry.editor.should == @teacher
    end
  end

  context "observer" do
    it "should allow observer by default" do
      course_with_teacher
      create_topic(@course, :title => "topic", :message => "topic")
      course_with_observer_logged_in(:course => @course)
      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                      { :controller => 'discussion_topics', :action => 'index', :format => 'json',
                        :course_id => @course.id.to_s })

      json.should_not be_nil
      json.should_not be_empty
    end

    it "should reject observer if read_forum role is false" do
      course_with_teacher
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      course_with_observer_logged_in(:course => @course)
      RoleOverride.create!(:context => @course.account, :permission => 'read_forum',
                           :enrollment_type => "ObserverEnrollment", :enabled => false)

      lambda { api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                      { :controller => 'discussion_topics', :action => 'index', :format => 'json',
                        :course_id => @course.id.to_s }) }.should raise_error
    end
  end

  context "read/unread state" do
    before(:each) do
      @topic = create_topic(@course, :title => "topic", :message => "topic")
      @entry = create_entry(@topic, :message => "top-level entry")
      @reply = create_reply(@entry, :message => "first reply")
    end

    it "should immediately mark messages you write as 'read'" do
      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                      { :controller => 'discussion_topics', :action => 'index', :format => 'json',
                        :course_id => @course.id.to_s })
      json.first["read_state"].should == "read"
      json.first["unread_count"].should == 0

      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.first["read_state"].should == "read"

      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
      json.first["read_state"].should == "read"
    end

    it "should be unread by default for a new user" do
      student_in_course(:active_all => true)
      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics.json",
                      { :controller => 'discussion_topics', :action => 'index', :format => 'json',
                        :course_id => @course.id.to_s })
      json.first["read_state"].should == "unread"
      json.first["unread_count"].should == 2

      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries.json",
        { :controller => 'discussion_topics_api', :action => 'entries', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
      json.first["read_state"].should == "unread"

      json = api_call(
        :get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies.json",
        { :controller => 'discussion_topics_api', :action => 'replies', :format => 'json',
          :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
      json.first["read_state"].should == "unread"
    end

    def call_mark_topic_read(course, topic)
      raw_api_call(:put, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/read.json",
                      { :controller => 'discussion_topics_api', :action => 'mark_topic_read', :format => 'json',
                        :course_id => course.id.to_s, :topic_id => topic.id.to_s })
    end

    def call_mark_topic_unread(course, topic)
      raw_api_call(:delete, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/read.json",
                      { :controller => 'discussion_topics_api', :action => 'mark_topic_unread', :format => 'json',
                        :course_id => course.id.to_s, :topic_id => topic.id.to_s })
    end

    it "should set the read state for a topic" do
      student_in_course(:active_all => true)
      call_mark_topic_read(@course, @topic)
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_true
      @topic.unread_count(@user).should == 2

      call_mark_topic_unread(@course, @topic)
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_false
      @topic.unread_count(@user).should == 2
    end

    it "should be idempotent for setting topic read state" do
      student_in_course(:active_all => true)
      call_mark_topic_read(@course, @topic)
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_true
      @topic.unread_count(@user).should == 2

      call_mark_topic_read(@course, @topic)
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_true
      @topic.unread_count(@user).should == 2
    end

    def call_mark_entry_read(course, topic, entry)
      raw_api_call(:put, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/entries/#{entry.id}/read.json",
                      { :controller => 'discussion_topics_api', :action => 'mark_entry_read', :format => 'json',
                        :course_id => course.id.to_s, :topic_id => topic.id.to_s, :entry_id => entry.id.to_s })
    end

    def call_mark_entry_unread(course, topic, entry)
      raw_api_call(:delete, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/entries/#{entry.id}/read.json?forced_read_state=true",
                      { :controller => 'discussion_topics_api', :action => 'mark_entry_unread', :format => 'json',
                        :course_id => course.id.to_s, :topic_id => topic.id.to_s, :entry_id => entry.id.to_s, :forced_read_state => "true" })
    end

    it "should set the read state for a entry" do
      student_in_course(:active_all => true)
      call_mark_entry_read(@course, @topic, @entry)
      response.status.should == '204 No Content'
      @entry.read?(@user).should be_true
      @entry.find_existing_participant(@user).should_not be_forced_read_state
      @topic.unread_count(@user).should == 1

      call_mark_entry_unread(@course, @topic, @entry)
      response.status.should == '204 No Content'
      @entry.read?(@user).should be_false
      @entry.find_existing_participant(@user).should be_forced_read_state
      @topic.unread_count(@user).should == 2

      call_mark_entry_read(@course, @topic, @entry)
      response.status.should == '204 No Content'
      @entry.read?(@user).should be_true
      @entry.find_existing_participant(@user).should be_forced_read_state
      @topic.unread_count(@user).should == 1
    end

    it "should be idempotent for setting entry read state" do
      student_in_course(:active_all => true)
      call_mark_entry_read(@course, @topic, @entry)
      response.status.should == '204 No Content'
      @entry.read?(@user).should be_true
      @topic.unread_count(@user).should == 1

      call_mark_entry_read(@course, @topic, @entry)
      response.status.should == '204 No Content'
      @entry.read?(@user).should be_true
      @topic.unread_count(@user).should == 1
    end

    def call_mark_all_as_read_state(new_state, opts = {})
      method = new_state == 'read' ? :put : :delete
      url = "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/read_all.json"
      expected_params = { :controller => 'discussion_topics_api', :action => "mark_all_#{new_state}", :format => 'json',
                        :course_id => @course.id.to_s, :topic_id => @topic.id.to_s }
      if opts.has_key?(:forced)
        url << "?forced_read_state=#{opts[:forced]}"
        expected_params[:forced_read_state] = opts[:forced].to_s
      end
      raw_api_call(method, url, expected_params)
    end

    it "should allow mark all as read without forced update" do
      student_in_course(:active_all => true)
      @entry.change_read_state('read', @user, :forced => true)

      call_mark_all_as_read_state('read')
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_true

      @entry.read?(@user).should be_true
      @entry.find_existing_participant(@user).should be_forced_read_state

      @reply.read?(@user).should be_true
      @reply.find_existing_participant(@user).should_not be_forced_read_state

      @topic.unread_count(@user).should == 0
    end

    it "should allow mark all as unread with forced update" do
      [@topic, @entry].each { |e| e.change_read_state('read', @user) }

      call_mark_all_as_read_state('unread', :forced => true)
      response.status.should == '204 No Content'
      @topic.reload
      @topic.read?(@user).should be_false

      @entry.read?(@user).should be_false
      @entry.find_existing_participant(@user).should be_forced_read_state

      @reply.read?(@user).should be_false
      @reply.find_existing_participant(@user).should be_forced_read_state

      @topic.unread_count(@user).should == 2
    end
  end

  context "subscribing" do
    before do
      student_in_course(:active_all => true)
      @topic1 = create_topic(@course, :user => @student)
      @topic2 = create_topic(@course, :user => @teacher, :require_initial_post => true)
    end

    def call_subscribe(topic, user, course=@course)
      @user = user
      raw_api_call(:put, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/subscribed",
                   { :controller => "discussion_topics_api", :action => "subscribe_topic", :format => "json", :course_id => course.id.to_s, :topic_id => topic.id.to_s})
      response.status.to_i
    end

    def call_unsubscribe(topic, user, course=@course)
      @user = user
      raw_api_call(:delete, "/api/v1/courses/#{course.id}/discussion_topics/#{topic.id}/subscribed",
                   { :controller => "discussion_topics_api", :action => "unsubscribe_topic", :format => "json", :course_id => course.id.to_s, :topic_id => topic.id.to_s})
      response.status.to_i
    end

    it "should allow subscription" do
      call_subscribe(@topic1, @teacher).should == 204
      @topic1.subscribed?(@teacher).should be_true
    end

    it "should allow unsubscription" do
      call_unsubscribe(@topic2, @teacher).should == 204
      @topic2.subscribed?(@teacher).should be_false
    end

    it "should be idempotent" do
      call_unsubscribe(@topic1, @teacher).should == 204
      call_subscribe(@topic1, @student).should == 204
    end

    context "when initial_post_required" do
      it "should allow subscription with an initial post" do
        @user = @student
        create_reply(@topic2, :message => 'first post!')
        call_subscribe(@topic2, @student).should == 204
        @topic2.subscribed?(@student).should be_true
      end

      it "should not allow subscription without an initial post" do
        call_subscribe(@topic2, @student).should == 403
      end

      it "should allow unsubscription even without an initial post" do
        @topic2.subscribe(@student)
        @topic2.subscribed?(@student).should be_true
        call_unsubscribe(@topic2, @student).should == 204
        @topic2.subscribed?(@student).should be_false
      end

      it "should unsubscribe a user if all their posts get deleted" do
        @user = @student
        @entry = create_reply(@topic2, :message => 'first post!')
        call_subscribe(@topic2, @student).should == 204
        @topic2.subscribed?(@student).should be_true
        @entry.destroy
        @topic2.subscribed?(@student).should be_false
      end
    end
  end

  context "subscription holds" do
    it "should hold when an initial post is required" do
      @topic = create_topic(@course, :require_initial_post => true)
      student_in_course(:active_all => true)
      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics",
                      { :controller => "discussion_topics", :action => "index", :format => "json", :course_id => @course.id.to_s })
      json[0]['subscription_hold'].should eql('initial_post_required')
    end

    it "should hold when the user isn't in a group set" do
      teacher_in_course(:active_all => true)
      group_discussion_assignment
      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics",
                      { :controller => "discussion_topics", :action => "index", :format => "json", :course_id => @course.id.to_s })
      json[0]['subscription_hold'].should  eql('not_in_group_set')
    end

    it "should hold when the user isn't in a group" do
      teacher_in_course(:active_all => true)
      group_discussion_assignment
      child = @topic.child_topics.first
      group = child.context
      json = api_call(:get, "/api/v1/groups/#{group.id}/discussion_topics",
                      { :controller => "discussion_topics", :action => "index", :format => "json", :group_id => group.id.to_s })
      json[0]['subscription_hold'].should eql('not_in_group')
    end
  end

  describe "threaded discussions" do
    before do
      student_in_course(:active_all => true)
      @topic = create_topic(@course, :threaded => true)
      @entry = create_entry(@topic)
      @sub1 = create_reply(@entry)
      @sub2 = create_reply(@sub1)
      @sub3 = create_reply(@sub2)
      @side2 = create_reply(@entry)
      @entry2 = create_entry(@topic)
    end

    context "in the original API" do
      it "should respond with information on the threaded discussion" do
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics",
                 { :controller => "discussion_topics", :action => "index", :format => "json", :course_id => @course.id.to_s })
        json[0]['discussion_type'].should == 'threaded'
      end

      it "should return nested discussions in a flattened format" do
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries",
                 { :controller => "discussion_topics_api", :action => "entries", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })
        json.size.should == 2
        json[0]['id'].should == @entry2.id
        e1 = json[1]
        e1['id'].should == @entry.id
        e1['recent_replies'].map { |r| r['id'] }.should == [@side2.id, @sub3.id, @sub2.id, @sub1.id]
        e1['recent_replies'].map { |r| r['parent_id'] }.should == [@entry.id, @sub2.id, @sub1.id, @entry.id]

        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies",
                 { :controller => "discussion_topics_api", :action => "replies", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
        json.size.should == 4
        json.map { |r| r['id'] }.should == [@side2.id, @sub3.id, @sub2.id, @sub1.id]
        json.map { |r| r['parent_id'] }.should == [@entry.id, @sub2.id, @sub1.id, @entry.id]
      end

      it "should allow posting a reply to a sub-entry" do
        json = api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@sub2.id}/replies",
                 { :controller => "discussion_topics_api", :action => "add_reply", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @sub2.id.to_s },
                 { :message => "ohai" })
        json['parent_id'].should == @sub2.id
        @sub4 = DiscussionEntry.order(:id).last
        @sub4.id.should == json['id']

        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{@entry.id}/replies",
                 { :controller => "discussion_topics_api", :action => "replies", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => @entry.id.to_s })
        json.size.should == 5
        json.map { |r| r['id'] }.should == [@sub4.id, @side2.id, @sub3.id, @sub2.id, @sub1.id]
        json.map { |r| r['parent_id'] }.should == [@sub2.id, @entry.id, @sub2.id, @sub1.id, @entry.id]
      end

      it "should set and return editor_id if editing another user's post" do
      end

      it "should fail if the max entry depth is reached" do
        entry = @entry
        (DiscussionEntry.max_depth - 1).times do
          entry = create_reply(entry)
        end
        json = api_call(:post, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entries/#{entry.id}/replies",
                 { :controller => "discussion_topics_api", :action => "add_reply", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :entry_id => entry.id.to_s },
                 { :message => "ohai" }, {}, {:expected_status => 400})
      end
    end

    context "in the updated API" do
      it "should return a paginated entry_list" do
        entries = [@entry2, @sub1, @side2]
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entry_list?per_page=2",
                  { :controller => "discussion_topics_api", :action => "entry_list", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s, :per_page => '2' },
                 { :ids => entries.map(&:id) })
        json.size.should == 2
        # response order is by id
        json.map { |e| e['id'] }.should == [@sub1.id, @side2.id]
        response['Link'].should match(/next/)
      end

      it "should return deleted entries, but with limited data" do
        @sub1.destroy
        json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/entry_list",
                  { :controller => "discussion_topics_api", :action => "entry_list", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s },
                 { :ids => @sub1.id })
        json.size.should == 1
        json.first['id'].should == @sub1.id
        json.first['deleted'].should == true
        json.first['read_state'].should == 'read'
        json.first['parent_id'].should == @entry.id
        json.first['updated_at'].should == @sub1.updated_at.as_json
        json.first['created_at'].should == @sub1.created_at.as_json
        json.first['edited_by'].should be_nil
      end
    end
  end

  context "materialized view API" do
    it "should respond with the materialized information about the discussion" do
      topic_with_nested_replies
      # mark a couple entries as read
      @user = @student
      @root2.change_read_state("read", @user)
      @reply3.change_read_state("read", @user)
      # have the teacher edit one of the student's replies
      @reply_reply1.editor = @teacher
      @reply_reply1.update_attributes(:message => '<p>censored</p>')

      @all_entries.each &:reload

      run_transaction_commit_callbacks
      run_jobs

      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/view",
                { :controller => "discussion_topics_api", :action => "view", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s })

      json['unread_entries'].size.should == 2 # two marked read, then ones this user wrote are never unread
      json['unread_entries'].sort.should == (@topic.discussion_entries - [@root2, @reply3] - @topic.discussion_entries.select { |e| e.user == @user }).map(&:id).sort

      json['participants'].sort_by { |h| h['id'] }.should == [
        { 'id' => @student.id, 'display_name' => @student.short_name, 'avatar_image_url' => "http://www.example.com/images/messages/avatar-50.png", "html_url" => "http://www.example.com/courses/#{@course.id}/users/#{@student.id}" },
        { 'id' => @teacher.id, 'display_name' => @teacher.short_name, 'avatar_image_url' => "http://www.example.com/images/messages/avatar-50.png", "html_url" => "http://www.example.com/courses/#{@course.id}/users/#{@teacher.id}" },
      ].sort_by { |h| h['id'] }

      reply_reply1_attachment_json = {
        "content-type"=>"application/loser",
        "url"=>"http://#{Account.default.domain}/files/#{@attachment.id}/download?download_frd=1&verifier=#{@attachment.uuid}",
        "filename"=>"unknown.loser",
        "display_name"=>"unknown.loser",
        "id" => @attachment.id,
        "size" => 100,
        'unlock_at' => nil,
        'locked' => false,
        'hidden' => false,
        'lock_at' => nil,
        'locked_for_user' => false,
        'hidden_for_user' => false,
        'created_at' => @attachment.created_at.as_json,
        'updated_at' => @attachment.updated_at.as_json,
        'thumbnail_url' => @attachment.thumbnail_url,
      }

      v0 = json['view'][0]
      v0['id'].should         == @root1.id
      v0['user_id'].should    == @student.id
      v0['message'].should    == 'root1'
      v0['parent_id'].should     be nil
      v0['created_at'].should == @root1.created_at.as_json
      v0['updated_at'].should == @root1.updated_at.as_json

      v0_r0 = v0['replies'][0]
      v0_r0['id'].should         == @reply1.id
      v0_r0['deleted'].should       be true
      v0_r0['parent_id'].should  == @root1.id
      v0_r0['created_at'].should == @reply1.created_at.as_json
      v0_r0['updated_at'].should == @reply1.updated_at.as_json

      v0_r0_r0 = v0_r0['replies'][0]
      v0_r0_r0['id'].should         == @reply_reply2.id
      v0_r0_r0['user_id'].should    == @student.id
      v0_r0_r0['message'].should    == 'reply_reply2'
      v0_r0_r0['parent_id'].should  == @reply1.id
      v0_r0_r0['created_at'].should == @reply_reply2.created_at.as_json
      v0_r0_r0['updated_at'].should == @reply_reply2.updated_at.as_json

      v0_r1 = v0['replies'][1]
      v0_r1['id'].should         == @reply2.id
      v0_r1['user_id'].should    == @teacher.id
      v0_r1['message'].should    == "<p><a href=\"http://#{Account.default.domain}/courses/#{@course.id}/files/#{@reply2_attachment.id}/download?verifier=#{@reply2_attachment.uuid}\">This is a file link</a></p>\n    <p>This is a video:\n      <video poster=\"http://#{Account.default.domain}/media_objects/0_abcde/thumbnail?height=448&amp;type=3&amp;width=550\" data-media_comment_type=\"video\" preload=\"none\" class=\"instructure_inline_media_comment\" data-media_comment_id=\"0_abcde\" controls=\"controls\" src=\"http://#{Account.default.domain}/courses/#{@course.id}/media_download?entryId=0_abcde&amp;redirect=1&amp;type=mp4\">link</video>\n    </p>"
      v0_r1['parent_id'].should  == @root1.id
      v0_r1['created_at'].should == @reply2.created_at.as_json
      v0_r1['updated_at'].should == @reply2.updated_at.as_json

      v0_r1_r0 = v0_r1['replies'][0]
      v0_r1_r0['id'].should          == @reply_reply1.id
      v0_r1_r0['user_id'].should     == @student.id
      v0_r1_r0['editor_id'].should   == @teacher.id
      v0_r1_r0['message'].should     == '<p>censored</p>'
      v0_r1_r0['parent_id'].should   == @reply2.id
      v0_r1_r0['created_at'].should  == @reply_reply1.created_at.as_json
      v0_r1_r0['updated_at'].should  == @reply_reply1.updated_at.as_json
      v0_r1_r0['attachment'].should  == reply_reply1_attachment_json
      v0_r1_r0['attachments'].should == [reply_reply1_attachment_json]

      v1 = json['view'][1]
      v1['id'].should         == @root2.id
      v1['user_id'].should    == @student.id
      v1['message'].should    == 'root2'
      v1['parent_id'].should     be nil
      v1['created_at'].should == @root2.created_at.as_json
      v1['updated_at'].should == @root2.updated_at.as_json

      v1_r0 = v1['replies'][0]
      v1_r0['id'].should         == @reply3.id
      v1_r0['user_id'].should    == @student.id
      v1_r0['message'].should    == 'reply3'
      v1_r0['parent_id'].should  == @root2.id
      v1_r0['created_at'].should == @reply3.created_at.as_json
      v1_r0['updated_at'].should == @reply3.updated_at.as_json
    end

    it "should include new entries if the flag is given" do
      course_with_teacher(:active_all => true)
      student_in_course(:course => @course, :active_all => true)
      @topic = @course.discussion_topics.create!(:title => "title", :message => "message", :user => @teacher, :discussion_type => 'threaded')
      @root1 = @topic.reply_from(:user => @student, :html => "root1")

      run_transaction_commit_callbacks
      run_jobs

      # make everything slightly in the past to test updating
      DiscussionEntry.update_all(:updated_at => 5.minutes.ago)
      @reply1 = @root1.reply_from(:user => @teacher, :html => "reply1")
      @reply2 = @root1.reply_from(:user => @teacher, :html => "reply2")

      json = api_call(:get, "/api/v1/courses/#{@course.id}/discussion_topics/#{@topic.id}/view",
                { :controller => "discussion_topics_api", :action => "view", :format => "json", :course_id => @course.id.to_s, :topic_id => @topic.id.to_s }, { :include_new_entries => '1' })
      json['unread_entries'].size.should == 2
      json['unread_entries'].sort.should == [@reply1.id, @reply2.id]

      json['participants'].map { |h| h['id'] }.sort.should == [@teacher.id, @student.id]

      json['view'].should == [
        'id' => @root1.id,
        'parent_id' => nil,
        'user_id' => @student.id,
        'message' => 'root1',
        'created_at' => @root1.created_at.as_json,
        'updated_at' => @root1.updated_at.as_json,
      ]

      # it's important that these are returned in created_at order
      json['new_entries'].should == [
        {
          'id' => @reply1.id,
          'created_at' => @reply1.created_at.as_json,
          'updated_at' => @reply1.updated_at.as_json,
          'message' => 'reply1',
          'parent_id' => @root1.id,
          'user_id' => @teacher.id,
        },
        {
          'id' => @reply2.id,
          'created_at' => @reply2.created_at.as_json,
          'updated_at' => @reply2.updated_at.as_json,
          'message' => 'reply2',
          'parent_id' => @root1.id,
          'user_id' => @teacher.id,
        },
      ]
    end
  end

  context "collection items" do
    before(:each) do
      @collection = @user.collections.create!(:name => 'test1', :visibility => 'private')
      @item = collection_item_model(:user_comment => "item 1", :user => @collection.context, :collection => @collection, :collection_item_data => collection_item_data_model(:link_url => "http://www.example.com/one"))
    end

    it "should return a discussion topic for an item" do
      json = api_call(:get, "/api/v1/collection_items/#{@item.id}/discussion_topics/self",
        { :collection_item_id => "#{@item.id}", :controller => "discussion_topics_api", :format => "json", :action => "show", :topic_id => "self"})
      json["discussion_subentry_count"].should == 0
      json["posted_at"].should be_nil
    end

    it "should return an empty discussion view for an item" do
      json = api_call(:get, "/api/v1/collection_items/#{@item.id}/discussion_topics/self/view",
        { :collection_item_id => "#{@item.id}", :controller => "discussion_topics_api", :format => "json", :action => "view", :topic_id => "self"})
      json.should == { "participants" => [], "unread_entries" => [], "forced_entries" => [], "view" => [], "new_entries" => [] }
      @item.discussion_topic.should be_new_record
    end

    it "should create a discussion topic when someone attempts to comment" do
      message = "oh that is awesome"
      json = nil
      expect {
        json = api_call(
          :post, "/api/v1/collection_items/#{@item.id}/discussion_topics/self/entries.json",
          { :controller => 'discussion_topics_api', :action => 'add_entry', :format => 'json',
            :collection_item_id => @item.id.to_s, :topic_id => "self" },
          { :message => message })
      }.to change(DiscussionTopic, :count).by(1)
      json.should_not be_nil
      json['id'].should_not be_nil
      @entry = DiscussionEntry.find_by_id(json['id'])
      @entry.should_not be_nil
      @entry.message.should == message
      @entry.user.should == @user
      @entry.parent_entry.should be_nil
    end

    it "should return a discussion's details for a collection item after there are posts" do
      @topic = @item.discussion_topic
      @topic.save!
      @entry1 = create_entry(@topic, :message => "loved it")
      @entry2 = create_entry(@topic, :message => "ditto")
      @topic.create_materialized_view
      json = api_call(:get, "/api/v1/collection_items/#{@item.id}/discussion_topics/self/view",
        { :collection_item_id => "#{@item.id}", :controller => "discussion_topics_api", :format => "json", :action => "view", :topic_id => "self"})
      json['participants'].length.should == 1
      json['unread_entries'].length.should == 0
      json['new_entries'].length.should == 0
      json['view'].should == [{
          "created_at" => @entry1.created_at.as_json,
          "updated_at" => @entry1.updated_at.as_json,
          "id" => @entry1.id,
          "user_id" => @user.id,
          "parent_id" => nil,
          "message" => "loved it"
        }, {
          "created_at" => @entry2.created_at.as_json,
          "updated_at" => @entry2.updated_at.as_json,
          "id" => @entry2.id,
          "user_id" => @user.id,
          "parent_id" => nil,
          "message" => "ditto"
      }]
    end

    it "should mark entries as read on a collection item" do
      Collection.where(:id => @collection).update_all(:visibility => 'public')
      @collection.reload
      topic = @item.discussion_topic
      topic.save!
      entry = create_entry(topic, :message => "loved it")

      student_in_course(:course => @course, :user => user_with_pseudonym)
      entry.read?(@user).should be_false
      json = raw_api_call(:put, "/api/v1/collection_items/#{@item.id}/discussion_topics/self/entries/#{entry.id}/read.json",
                { :controller => 'discussion_topics_api', :action => 'mark_entry_read', :format => 'json',
                  :collection_item_id => @item.id.to_s, :topic_id => "self", :entry_id => entry.id.to_s })
      entry.reload.read?(@user).should be_true
    end
  end
end

def create_attachment(context, opts={})
  opts[:uploaded_data] ||= StringIO.new('attachment content')
  opts[:filename] ||= 'content.txt'
  opts[:display_name] ||= opts[:filename]
  opts[:folder] ||= Folder.unfiled_folder(context)
  attachment = context.attachments.build(opts)
  attachment.save!
  attachment
end

def create_topic(context, opts={})
  attachment = opts.delete(:attachment)
  opts[:user] ||= @user
  topic = context.discussion_topics.build(opts)
  topic.attachment = attachment if attachment
  topic.save!
  topic
end

def create_subtopic(topic, opts={})
  opts[:user] ||= @user
  subtopic = topic.context.discussion_topics.build(opts)
  subtopic.root_topic_id = topic.id
  subtopic.save!
  subtopic
end

def create_entry(topic, opts={})
  attachment = opts.delete(:attachment)
  created_at = opts.delete(:created_at)
  opts[:user] ||= @user
  entry = topic.discussion_entries.build(opts)
  entry.attachment = attachment if attachment
  entry.created_at = created_at if created_at
  entry.save!
  entry
end

def create_reply(entry, opts={})
  created_at = opts.delete(:created_at)
  opts[:user] ||= @user
  opts[:html] ||= opts.delete(:message)
  opts[:html] ||= "<p>This is a test message</p>"
  reply = entry.reply_from(opts)
  reply.created_at = created_at if created_at
  reply.save!
  reply
end
