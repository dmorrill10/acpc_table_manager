require 'support/spec_helper'
require 'acpc_table_manager'
require 'json'

PWD = File.dirname(__FILE__)
CONFIG_DATA = {
  'table_manager_constants' => '%{pwd}/../support/table_manager.json',
  'match_log_directory' => '%{pwd}/log/match_logs',
  'exhibition_constants' => '%{pwd}/../support/exhibition.json',
  'log_directory' => '%{pwd}/log',
  'data_directory' => '%{pwd}/db',
  'redis_config_file' => 'default'
}

def my_setup
  tmp_dir = File.join(PWD, 'exe_test_tmp')
  FileUtils.rm_rf tmp_dir if File.directory?(tmp_dir)
  FileUtils.mkdir_p tmp_dir
  config_file = File.join(tmp_dir, 'config.yml')
  File.open(config_file, 'w') do |f|
    f.puts YAML.dump(CONFIG_DATA)
  end
  redis_pid = begin
    AcpcTableManager.new_redis_connection.ping
  rescue Redis::CannotConnectError
    STDERR.puts "WARNING: Default redis server had to be started before the test."
    Process.spawn('redis-server --save "" --appendonly no')
  else
    nil
  end
  patient_pid = Process.spawn(
    "#{File.join(PWD, '..', 'exe', 'acpc_table_manager')} -t #{config_file}"
  )
  sleep 0.5
  return tmp_dir, config_file, redis_pid, patient_pid
end
tmp_dir, config_file, redis_pid, patient_pid = my_setup

def my_teardown(tmp_dir, config_file, redis_pid, patient_pid)
  AcpcDealer.kill_process(redis_pid) if redis_pid
  AcpcDealer.kill_process(patient_pid)
  # FileUtils.rm_rf tmp_dir
  begin
    Timeout.timeout(3) do
      while (
        (redis_pid && AcpcDealer.process_exists?(redis_pid)) ||
        AcpcDealer.process_exists?(patient_pid)
      )
        sleep 0.1
      end
    end
  rescue Timeout::Error # @todo Necessary for TravisCI for some reason
  end
  Process.wait
end
MiniTest.after_run { my_teardown(tmp_dir, config_file, redis_pid, patient_pid) }

describe 'exe/acpc_table_manager' do
  let(:game) { 'two_player_nolimit' }
  let(:random_seed) { 9001 }

  before do
    AcpcTableManager.unload!
    File.exist?(config_file).must_equal true
    AcpcTableManager.load! config_file
    AcpcDealer.process_exists?(redis_pid).must_equal(true) if redis_pid
    AcpcDealer.process_exists?(patient_pid).must_equal true
  end

  def match_name(players)
    AcpcTableManager.match_name(
      game_def_key: game,
      players: players,
      time: false
    )
  end

  let(:proxy_name) { 'Proxy' }
  let(:to_channel) do
    "#{AcpcTableManager.player_id(game, proxy_name, seat)}-to-proxy"
  end
  let(:from_channel) do
    "#{AcpcTableManager.player_id(game, proxy_name, seat)}-from-proxy"
  end
  let(:seat) { players.index(proxy_name) }
  let(:redis) { AcpcTableManager.new_redis_connection }
  def start_match
    redis.rpush(
      'table-manager',
      {
        'game_def_key' => game,
        'players' => players,
        'random_seed' => random_seed
      }.to_json
    )
    sleep 0.5
  end
  def play_match
    start_match
    running_matches = AcpcTableManager.running_matches(game)
    running_matches.length.must_equal 1
    match = running_matches.first
    name = match[:name]
    proxy_pid = match[:players][1][:pid]

    log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.log")
    File.exist?(log_file).must_equal true
    actions_log_file = File.join(AcpcTableManager.config.match_log_directory, "#{name}.actions.log")
    File.exist?(actions_log_file).must_equal true

    AcpcDealer.process_exists?(match[:dealer][:pid]).must_equal true
    match[:name].must_match(/^#{match_name(players)}/)
    match[:dealer][:port_numbers].length.must_equal players.length
    match[:dealer][:log_directory].must_equal AcpcTableManager.config.match_log_directory
    match[:players].length.must_equal players.length

    match[:players].each_with_index do |player, i|
      player[:name].must_equal players[i]
      player[:pid].must_be :>, 0
      AcpcDealer.process_exists?(player[:pid]).must_equal true
    end

    act = ->(i) do
      redis.rpush(
        to_channel,
        {
          AcpcTableManager.config.action_key => (
            case i % 3
            when 0
              'c'
            when 1
              'r1'
            when 2
              'f'
            end
          )
        }.to_json
      )
    end

    i = 0
    from_proxy = AcpcTableManager.new_redis_connection
    while AcpcDealer.process_exists?(proxy_pid) do
      list, message = from_proxy.blpop(from_channel, 1)
      # ap JSON.parse(message) if message
      act.call i
      i += 1
    end

    match[:players].each_with_index do |player, i|
      AcpcDealer.process_exists?(player[:pid]).must_equal false
      if AcpcDealer.process_exists?(player[:pid])
        AcpcDealer.kill_process player[:pid]
        Timeout.timeout(3) do
          while AcpcDealer.process_exists?(player[:pid])
            sleep 0.1
          end
        end
      end
    end
    AcpcDealer.process_exists?(match[:dealer][:pid]).must_equal false
    if AcpcDealer.process_exists?(match[:dealer][:pid])
      AcpcDealer.kill_process match[:dealer][:pid]
      Timeout.timeout(3) do
        while AcpcDealer.process_exists?(match[:dealer][:pid])
          sleep 0.1
        end
      end
    end
  end

  describe 'in seat 2' do
    let(:players) { ['TestingBot', proxy_name] }
    it 'works' do
      play_match
    end
  end
  describe 'in seat 1' do
    let(:players) { [proxy_name, 'TestingBot'] }
    it 'works' do
      play_match
    end
  end
end
