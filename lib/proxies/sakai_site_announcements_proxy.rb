# encoding: utf-8
class SakaiSiteAnnouncementsProxy < SakaiProxy

  def initialize(options = {})
    super(options)
    @site_id = options[:site_id]
    @fake_now = options[:fake_now] || Settings.sakai_proxy.fake_now
    @message_max_length = options[:message_max_length] || 1000
  end

  def self.cache_key(site_id)
    "global/#{self.name}/#{site_id}"
  end

  # For test support
  def message_max_length
    @message_max_length
  end

  def get_announcements
    end_time = @fake_now || DateTime.now
    start_time = end_time.advance(days: -10)
    self.class.fetch_from_cache @site_id do
      announcements = []
      @tool_id = SakaiData.get_announcement_tool_id(@site_id)
      if (@tool_id)
        ann_rows = SakaiData.get_announcements(@site_id, start_time, end_time)
        ann_rows.each do |row|
          announcement = parse_announcement(row)
          announcements << announcement if announcement
        end
      end
      announcements
    end
  end

  private

  def announcement_url(message_id)
    "#{Settings.sakai_proxy.host}/portal/directtool/#{@tool_id}?itemReference=/announcement/msg/#{@site_id}/main/#{message_id}&panel=Main&sakai_action=doShowmetadata"
  end

  def attachment_url(relative_url)
    "#{Settings.sakai_proxy.host}/access#{relative_url}"
  end

  def parse_announcement(ann_row)
    channel_id = ann_row['channel_id']
    if (site_id = %r{/announcement/channel/(.+)/main}.match(channel_id))
      ann = {}
      ann['site_id'] = site_id[1]
      %w'message_id message_date owner'.each do |col|
        ann[col] = ann_row[col]
      end
      ann['url'] = announcement_url(ann['message_id'])
      doc = Nokogiri::XML::Document.parse(ann_row['xml']).at_xpath('message')
      # The 'body-html' attribute contains the rich-text version of the announcement body, and this is what
      # is displayed by Sakai. CalCentral restricts itself to the HTML-stripped "body" attribute, which
      # is generally much smaller. The same basic encoding is used to store both.
      message_text = doc['body'].split('&#xa;').collect {|enc|
        Base64.decode64(enc).force_encoding('UTF-8')
      }.join
      ann['message'] = message_text.squish.truncate(@message_max_length)
      ann['title'] = doc.at_xpath('header')['subject']
      # Relative-url '/content/attachment/XXX/Announcements/YYY/FILE NAME.EXT' becomes link
      # 'https://HOST/access/content/attachment/XXX/Announcements/YYY/FILE%20NAME.EXT'.
      doc.xpath('header/attachment').each do |el|
        ann['attachments'] ||= []
        if (url = el['relative-url'])
          ann['attachments'].push(attachment_url(url))
        else
          Rails.logger.warn("Unexpected attachment element: #{el}")
        end
      end
      doc.xpath('properties/property').each do |prop|
        name = prop['name']
        # Notification levels: 'r' for required; 'n' for none; 'o' for optional
        #
        # "assignmentReference"=> "/assignment/a/29fc31ae-ff14-419f-a132-5576cae2474e/7dc0c8e4-ec37-4457-ab15-97378e92fab5"}
        # shows as:
        # <a href="https://HOST/portal/directtool/37c2f61c-66f9-4abb-bb07-a9e6670d4bcd?assignmentId=/assignment/a/29fc31ae-ff14-419f-a132-5576cae2474e/7dc0c8e4-ec37-4457-ab15-97378e92fab5&panel=Main&sakai_action=doView_assignment">Do this then do that</a>
        if %w'releaseDate retractDate assignmentReference notificationLevel'.include?(name)
          ann[name] = Base64.decode64(prop['value'])
        end
      end
      ann
    else
      # The only other sort of CHANNEL_ID I've seen supports the bSpace-wide "Message of the Day"
      # feature, at '/announcement/channel/!site/motd'.
      # Sakai CLE also supposedly allows announcements targeting specific groups within
      # a site, but I haven't seen that in the wild yet.
      if channel_id != '/announcement/channel/!site/motd'
        Rails.logger.warn("Skipping siteless announcement for #{channel_id}")
      end
      nil
    end
  end

end