describe Match do
  describe Match::Encryption::OpenSSL do
    before do
      @directory = Dir.mktmpdir
      profile_path = "./match/spec/fixtures/test.mobileprovision"
      FileUtils.cp(profile_path, @directory)
      @full_path = File.join(@directory, "test.mobileprovision")
      @content = File.binread(@full_path)
      @git_url = "https://github.com/fastlane/fastlane/tree/master/so_random"
      allow(Dir).to receive(:mktmpdir).and_return(@directory)
      stub_const('ENV', { "MATCH_PASSWORD" => '2"QAHg@v(Qp{=*n^', "DEBUG" => "Y" })

      @e = Match::Encryption::OpenSSL.new(
        keychain_name: @git_url,
        working_directory: @directory
      )
    end

    xit "first encrypt, different content, then decrypt, initial content again" do
      @e.encrypt_files
      expect(File.binread(@full_path)).to_not(eq(@content))

      @e.decrypt_files
      expect(File.binread(@full_path)).to eq(@content)
    end

    400.times do
      it "raises an exception if invalid password is passed" do
        stub_const('ENV', { "MATCH_PASSWORD" => '2"QAHg@v(Qp{=*n^' })
        encrypt_files = []
        expect(@e).to receive(:encrypt_specific_file).once.and_wrap_original do |m, *args|
          encrypt_files << args[0]
          m.call(*args)
        end

        @e.encrypt_files
        expect(File.read(@full_path)).to_not(eq(@content))

        puts "HI #{encrypt_files.count}"
        puts encrypt_files

        decrypt_files = []
        expect(@e).to receive(:decrypt_specific_file).twice.and_wrap_original do |m, *args| 
          decrypt_files << args[0]
          m.call(*args)
        end

        stub_const('ENV', { "MATCH_PASSWORD" => "invalid" })
        expect do
          @e.decrypt_files
          puts "ERROR: files processed"
          puts decrypt_files

          read_content = File.binread(@full_path)
          puts "SAME CONTENT ? #{read_content == @content}"
        end.to raise_error("Invalid password passed via 'MATCH_PASSWORD'")
      end
    end

    xit "raises an exception if no password is supplied" do
      stub_const('ENV', { "MATCH_PASSWORD" => "" })
      expect do
        @e.encrypt_files
      end.to raise_error("No password supplied")
    end

    xit "doesn't raise an exception if no env var is supplied but custom password is" do
      stub_const('ENV', { "MATCH_PASSWORD" => "" })
      expect do
        @e.encrypt_files(password: "some custom password")
      end.to_not(raise_error)
    end

    xit "given a custom password argument, then it should be given precedence when encrypting file, even when MATCH_PASSWORD is set" do
      stub_const('ENV', { "MATCH_PASSWORD" => "something else" })
      new_password = '2"QAHg@v(Qp{=*n^'
      @e.encrypt_files(password: new_password)
      expect(File.binread(@full_path)).to_not(eq(@content))

      stub_const('ENV', { "MATCH_PASSWORD" => new_password })
      @e.decrypt_files
      expect(File.binread(@full_path)).to eq(@content)
    end
  end
end
