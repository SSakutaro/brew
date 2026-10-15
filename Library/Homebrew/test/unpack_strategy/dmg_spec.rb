# typed: true
# frozen_string_literal: true

require_relative "shared_examples"

RSpec.describe UnpackStrategy::Dmg, :needs_macos do
  describe "#mount" do
    subject(:path) { TEST_FIXTURE_DIR/"cask/container.dmg" }

    include_examples "UnpackStrategy::detect"

    specify "#extract" do
      allow(Sandbox).to receive(:isolate_operation?).and_return(true)
      allow(Sandbox).to receive(:operation)

      Dir.mktmpdir do |dir|
        unpack_dir = Pathname(dir)
        mount = instance_double(UnpackStrategy::Dmg::Mount)
        unpack_strategy = described_class.new(path)

        allow(unpack_strategy).to receive(:mount).with(verbose: false).and_yield([mount])
        allow(mount).to receive(:extract).with(to: unpack_dir, verbose: false) do
          (unpack_dir/"container").mkpath
        end

        unpack_strategy.extract(to: unpack_dir)
        expect(unpack_dir.children(false).map(&:to_s)).to contain_exactly("container")
      end
    end

    it "does not treat an unrelated attach failure as a license agreement" do
      unpack_strategy = described_class.new(path)
      attach_result = instance_double(SystemCommand::Result, success?: false, stdout: "")
      attach_error = ErrorDuringExecution.new(["hdiutil", "attach"], status: 1)

      allow(unpack_strategy).to receive(:system_command).and_return(attach_result)
      expect(attach_result).to receive(:assert_success!).and_raise(attach_error)
      expect(unpack_strategy).not_to receive(:system_command!)

      expect { unpack_strategy.mount { nil } }.to raise_error(attach_error)
    end
  end

  describe "#extract" do
    let(:unpack_strategy) { described_class.new(TEST_FIXTURE_DIR/"cask/container.dmg") }
    let!(:mount) { UnpackStrategy::Dmg::Mount.new(mktmpdir) }
    let(:events) { [] }

    before do
      attach_result = instance_double(
        SystemCommand::Result,
        success?: true,
        plist:    { "system-entities" => [{ "mount-point" => mount.path.to_s }] },
      )
      allow(UnpackStrategy::Dmg::Mount).to receive(:new).and_return(mount)
      allow(unpack_strategy).to receive(:system_command) do
        events << :attach
        attach_result
      end
      allow(unpack_strategy).to receive(:sleep)
      allow(mount).to receive(:eject) { events << :eject }
      allow(Sandbox).to receive(:isolate_operation?).and_return(true)
    end

    it "ejects and remounts a disk image when its sandboxed file listing is empty" do
      allow(Sandbox).to receive(:operation) do
        events << :extract
        (events.count(:extract) == 1) ? JSON.generate("empty_dmg_bom") : "null"
      end

      unpack_strategy.extract(to: mktmpdir)

      expect(events).to eq([:attach, :extract, :eject, :attach, :extract, :eject])
    end

    it "stops after three mounts with empty file listings" do
      allow(Sandbox).to receive(:operation).and_return(JSON.generate("empty_dmg_bom"))

      expect { unpack_strategy.extract(to: mktmpdir) }.to raise_error(UnpackStrategy::Dmg::Bom::EmptyError)
      expect(events).to eq([:attach, :eject, :attach, :eject, :attach, :eject])
    end

    it "ejects without remounting for other worker failures" do
      error = ErrorDuringExecution.new(["ditto"], status: 1)
      allow(Sandbox).to receive(:operation).and_raise(error)

      expect { unpack_strategy.extract(to: mktmpdir) }.to raise_error(error)
      expect(events).to eq([:attach, :eject])
    end
  end
end
