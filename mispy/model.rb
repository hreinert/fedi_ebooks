# encoding: utf-8

# rubocop:disable Style/StringLiterals

require "active_record"
require "bulk_insert"
require "csv"
require "digest/md5"
require "set"
require "uri"
require "yajl/json_gem"
require_relative "nlp"

class Model
  # Database classes
  class Tokens < ActiveRecord::Base
  end

  class Sentences < ActiveRecord::Base
  end

  class Keywords < ActiveRecord::Base
  end

  class Unigrams < ActiveRecord::Base
  end

  class Bigrams < ActiveRecord::Base
  end

  # Reply generation uses this
  INTERIM = -1

  # @return [Array<String>]
  # An array of unique tokens. This is the main source of actual strings
  # in the model. Manipulation of a token is done using its index
  # in this array, which we call a "tiki"
  attr_accessor :tokens

  # @return [Array<Array<Integer>>]
  # Sentences represented by arrays of tikis
  attr_accessor :sentences

  # @return [Array<String>]
  # The top 200 most important keywords, in descending order
  attr_accessor :keywords

  # @return String
  # Path to the database
  attr_accessor :path

  # For Pleroma
  LINEBREAK_PLACEHOLDER = "&_#_1_0_;"
  HTML_LINEBREAK = "&#10;"

  # Set ups the database connection
  # @param path [String]
  def setup_db(path)
    ActiveRecord::Base.clear_active_connections!
    ActiveRecord::Base.establish_connection(
      :adapter => "sqlite3",
      :database => path
    )
  end

  # Creates the database for the model
  # @param path [String]
  def create_db(path)
    setup_db(path)

    ActiveRecord::Schema.define do
      create_table :tokens, id: false, if_not_exists: true do |table|
        table.column :token_id, :integer
        table.column :token, :string
      end

      create_table :sentences, id: false, if_not_exists: true do |table|
        table.column :sentence, :string
      end

      create_table :keywords, id: false, if_not_exists: true do |table|
        table.column :keyword, :string
      end

      create_table :unigrams, id: false, if_not_exists: true do |table|
        table.column :next_tiki, :integer
        table.column :unigram, :string
      end

      create_table :bigrams, id: false, if_not_exists: true do |table|
        table.column :next_tiki, :integer
        table.column :tiki, :integer
        table.column :bigram, :string
      end
    end
  end

  # Populates the database for the model
  def save()
    create_db(@path)

    Tokens.bulk_insert do |worker|
      i = 0
      @tokens.each do |d|
        worker.add token_id: i, token: d
        i += 1
      end
    end

    Sentences.bulk_insert do |worker|
      # Attempting to make the numbers in the array searchable by a SQL statement
      # It will look like this => |10|54|642|
      @sentences.each { |d| worker.add sentence: "|" + d.join("|").to_s + "|" if !d.empty? }
    end

    Keywords.bulk_insert do |worker|
      @keywords.each { |d| worker.add keyword: d }
    end

    # Geneate default Unigrams and Bigrams
    default_generator()

    log "Database file created, run the software again."
    ActiveRecord::Base.clear_active_connections!
    exit 0
  end

  def initialize(path)
    ActiveRecord::Base.logger = Logger.new(STDERR)
    ActiveRecord::Base.logger.level = :error

    @path = path
    @tokens = []
    # Reverse lookup tiki by token, for faster generation
    @tikis = {}
  end

  # Reverse lookup a token index from a token
  # @param token [String]
  # @return [Integer]
  def tikify(token)
    if @tikis.has_key?(token) then
      return @tikis[token]
    else
      (@tokens.length + 1) % 1000 == 0 and puts "#{@tokens.length + 1} tokens"
      @tokens << token
      return @tikis[token] = @tokens.length - 1
    end
  end

  # Convert a body of text into arrays of tikis
  # @param text [String]
  # @return [Array<Array<Integer>>]
  def mass_tikify(text)
    sentences = NLP.sentences(text)

    sentences.map do |s|
      tokens = NLP.tokenize(s).reject do |t|
        # Don't include usernames/urls as tokens
        (t.include?("@") && t.length > 1) || t.include?("http")
      end

      tokens.map { |t| tikify(t) }
    end
  end

  # Consume a corpus into this model
  # @param path [String]
  def consume(path)
    content = File.read(path, :encoding => "utf-8")

    if path.split(".")[-1] == "json"
      log "Reading json corpus from #{path}"
      json_content = JSON.parse(content)
      twitter_json = content.include?("\"retweeted\": false")

      if twitter_json
        lines = json_content.map do |tweet|
          tweet["text"]
        end
      else
        statuses = json_content['statuses'] unless !json_content.include?("statuses")
        statuses = json_content if !json_content.include?("statuses")

        lines = statuses.map do |status|
          pleroma_cleanup(status)
        end

        lines.compact! # Remove nil values
      end
    elsif path.split(".")[-1] == "csv"
      log "Reading CSV corpus from #{path}"
      content = CSV.parse(content)
      header = content.shift
      text_col = header.index("text")
      lines = content.map do |tweet|
        tweet[text_col]
      end
    else
      log "Reading plaintext corpus from #{path} (if this is a json or csv file, please rename the file with an extension and reconsume)"
      lines = content.split("\n")
    end

    consume_lines(lines)
  end

  # Consume a sequence of lines
  # @param lines [Array<String>]
  def consume_lines(lines)
    log "Removing commented lines"

    statements = []
    lines.each do |l|
      next if l.start_with?("#") # Remove commented lines

      statements << NLP.normalize(l)
    end

    text = statements.join("\n").encode("UTF-8", :invalid => :replace)
    lines = nil; statements = nil # Allow garbage collection

    log "Tokenizing #{text.count("\n")} statements"

    @sentences = mass_tikify(text)

    log "Ranking keywords"
    @keywords = NLP.keywords(text).top(200).map(&:to_s)
    log "Top keywords: #{@keywords[0]} #{@keywords[1]} #{@keywords[2]}"

    self
  end

  # Consume multiple corpuses into this model
  # @param paths [Array<String>]
  def consume_all(paths)
    lines = []
    paths.each do |path|
      content = File.read(path, :encoding => "utf-8")

      if path.split(".")[-1] == "json"
        log "Reading json corpus from #{path}"
        json_content = JSON.parse(content)
        twitter_json = content.include?("\"retweeted\"")

        if twitter_json
          l = json_content.map do |tweet|
            tweet["text"]
          end
        else
          statuses = json_content['statuses'] unless !json_content.include?("statuses")
          statuses = json_content if !json_content.include?("statuses")

          l = statuses.map do |status|
            pleroma_cleanup(status)
          end

          l.compact! # Remove nil values
        end

        lines.concat(l)
      elsif path.split(".")[-1] == "csv"
        log "Reading CSV corpus from #{path}"
        content = CSV.parse(content)
        header = content.shift
        text_col = header.index("text")
        l = content.map do |tweet|
          tweet[text_col]
        end
        lines.concat(l)
      else
        log "Reading plaintext corpus from #{path}"
        l = content.split("\n")
        lines.concat(l)
      end
    end
    consume_lines(lines)
  end

  # Correct encoding issues in generated text
  # @param text [String]
  # @return [String]
  def fix(text)
    NLP.htmlentities.decode text
  end

  # Check if an array of tikis comprises a valid tweet
  # @param tikis [Array<Integer>]
  # @param limit Integer how many chars we have left
  def valid_tweet?(tikis, limit)
    tweet = NLP.reconstruct(tikis, @tokens)
    tweet.length <= limit && !NLP.unmatched_enclosers?(tweet)
  end

  # Generate some text
  # @param limit [Integer] available characters
  # @param retry_limit [Integer] how many times to retry on invalid tweet
  # @return [String]
  def make_statement(limit = 140, relevant_sentences = nil, retry_limit = 10)
    responding = !relevant_sentences.nil?
    retries = 0
    tweet = ""

    while (tikis = generate(3, :bigrams)) do
      # log "Attempting to produce tweet try #{retries+1}/#{retry_limit}"
      break if (tikis.length > 3 || responding) && valid_tweet?(tikis, limit)

      retries += 1
      break if retries >= retry_limit
    end

    if verbatim?(tikis) && tikis.length > 3 # We made a verbatim tweet by accident
      # log "Attempting to produce unigram tweet try #{retries+1}/#{retry_limit}"
      while (tikis = generate(3, :unigrams)) do
        break if valid_tweet?(tikis, limit) && !verbatim?(tikis)

        retries += 1
        break if retries >= retry_limit
      end
    end

    tweet = NLP.reconstruct(tikis, @tokens)

    if retries >= retry_limit
      log "Unable to produce valid non-verbatim tweet; using \"#{tweet}\""
    end

    fix tweet
  end

  # Test if a sentence has been copied verbatim from original
  # @param tikis [Array<Integer>]
  # @return [Boolean]
  def verbatim?(tikis)
    @sentences.include?(tikis)
  end

  # Finds relevant and slightly relevant tokenized sentences to input
  # comparing non-stopword token overlaps
  # @param sentences [Array<Array<Integer>>]
  # @param input [String]
  # @return [Array<Array<Array<Integer>>, Array<Array<Integer>>>]
  def find_relevant(sentences, input)
    relevant = []
    slightly_relevant = []

    tokenized = NLP.tokenize(input).map(&:downcase)

    sentences.each do |sent|
      tokenized.each do |token|
        if sent.map { |tiki| @tokens[tiki].downcase }.include?(token)
          relevant << sent unless NLP.stopword?(token)
          slightly_relevant << sent
        end
      end
    end

    [relevant, slightly_relevant]
  end

  # Generates a response by looking for related sentences
  # in the corpus and building a smaller generator from these
  # @param input [String]
  # @param limit [Integer] characters available for response
  # @param sentences [Array<Array<Integer>>]
  # @return [String]
  def make_response(input, limit = 140, sentences = @sentences)
    relevant, slightly_relevant = find_relevant(sentences, input)

    if relevant.length >= 3
      make_statement(limit, relevant)
    elsif slightly_relevant.length >= 5
      make_statement(limit, slightly_relevant)
    else
      make_statement(limit)
    end
  end

  # Cleans up the status for ActivityPub
  # @param status [String]
  # @param html_linebreaks [Boolean] try to replace line breaks with HTML ones
  def pleroma_cleanup(status, html_linebreaks: false)
    return nil if !status['reblog'].nil?

    content = status['content']
    return nil if content.nil?

    # Try to remove line breaks at the start of the post
    10.times do
      content = content.strip.gsub(/^<p>/, "") || content
      content = content.strip.gsub(/^<br\/>/, "") || content
    end

    content = content.gsub(/<a.*?<\/a>/, "")
    content = content.gsub("<br/>", " ") unless html_linebreaks
    content = content.gsub("<p>", " ") unless html_linebreaks
    content = content.gsub("<br/>", " #{LINEBREAK_PLACEHOLDER} ") if html_linebreaks
    content = content.gsub("<p>", " #{LINEBREAK_PLACEHOLDER} ") if html_linebreaks
    content = content.gsub(/<("[^"]*"|'[^']*'|[^'">])*>/, '') # Remove HTML
    content = NLP.htmlentities.decode content.gsub('“', '"').gsub('”', '"').gsub('’', "'").gsub('…', '...')

    return nil if content.nil?

    mentions = status['mentions']
    mentions.each do |m|
      content = content.gsub("@" + m['acct'], '') || content
      content = content.gsub("@" + m['username'], '') || content
      content = pleroma_filter(content)
    end

    content = pleroma_filter(content)

    if html_linebreaks
      # Try to remove line breaks at the start of the post (again)
      10.times do
        content = content.strip.gsub(/^#{LINEBREAK_PLACEHOLDER}/, "") || content
      end

      content = content.gsub(LINEBREAK_PLACEHOLDER, HTML_LINEBREAK)

      while content.end_with? HTML_LINEBREAK
        if content == HTML_LINEBREAK
          content = ""
          break
        end

        content = content.slice(content.rindex(HTML_LINEBREAK), HTML_LINEBREAK.size)
        content = content.strip
      end

      while content.start_with? HTML_LINEBREAK
        content = content.sub(HTML_LINEBREAK, "")
        content = content.strip
      end
    end

    if content != ""
      return content
    else
      return nil
    end
  end

  # Filter content for ActivityPub
  # @param content [String]
  def pleroma_filter(content)
    content = content.gsub(/\B[@]\S+\b/, '') || content

    urls = URI.extract(content, ['http', 'https'])
    urls.each do |url|
      content = content.gsub(url, '')
    end

    content = content.squeeze(" ") || content
    content.strip
  end

  # Generate a recombined sequence of tikis
  # @param passes [Integer] number of times to recombine
  # @param n [Symbol] :unigrams or :bigrams (affects how conservative the model is)
  # @return [Array<Integer>]
  def generate(passes = 5, n = :unigrams)
    index = rand(@sentences.length)
    tikis = @sentences[index]
    used = [index] # Sentences we"ve already used
    verbatim = [tikis] # Verbatim sentences to avoid reproducing

    0.upto(passes - 1) do
      varsites = {} # Map bigram start site => next tiki alternatives

      tikis.each_with_index do |tiki, i|
        next_tiki = tikis[i + 1]
        break if next_tiki.nil?

        alternatives = (n == :unigrams) ? @unigrams[next_tiki] : @bigrams[tiki][next_tiki]
        # Filter out suffixes from previous sentences
        alternatives.reject! { |a| a[1] == INTERIM || used.include?(a[0]) }
        varsites[i] = alternatives unless alternatives.empty?
      end

      variant = nil
      varsites.to_a.shuffle.each do |site|
        start = site[0]

        site[1].shuffle.each do |alt|
          verbatim << @sentences[alt[0]]
          suffix = @sentences[alt[0]][alt[1]..-1]
          potential = tikis[0..start + 1] + suffix

          # Ensure we"re not just rebuilding some segment of another sentence
          unless verbatim.find { |v| NLP.subseq?(v, potential) || NLP.subseq?(potential, v) }
            used << alt[0]
            variant = potential
            break
          end
        end

        break if variant
      end

      # If we failed to produce a variation from any alternative, there
      # is no use running additional passes-- they"ll have the same result.
      break if variant.nil?

      tikis = variant
    end

    tikis
  end

  def default_generator()
    @unigrams = {}
    @bigrams = {}

    @sentences.each_with_index do |tikis, i|
      last_tiki = INTERIM
      tikis.each_with_index do |tiki, j|
        @unigrams[last_tiki] ||= []
        @unigrams[last_tiki] << [i, j]

        @bigrams[last_tiki] ||= {}
        @bigrams[last_tiki][tiki] ||= []

        if j == tikis.length - 1 # Mark sentence endings
          @unigrams[tiki] ||= []
          @unigrams[tiki] << [i, INTERIM]
          @bigrams[last_tiki][tiki] << [i, INTERIM]
        else
          @bigrams[last_tiki][tiki] << [i, j + 1]
        end

        last_tiki = tiki
      end
    end

    Unigrams.bulk_insert do |worker|
      @unigrams.each do |key, values|
        values.each do |v|
          unigram = "|" + v.join("|").to_s + "|"
          worker.add next_tiki: key, unigram: unigram
        end
      end
    end

    Bigrams.bulk_insert do |worker|
      @bigrams.each do |key, subkeys|
        subkeys.each do |subkey, value|
          value.each do |v|
            bigram = + "|" + v.join("|").to_s + "|"
            worker.add next_tiki: key, tiki: subkey, bigram: bigram
          end
        end
      end
    end
  end
end
