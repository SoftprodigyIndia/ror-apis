class Api::V1::UsersController < Api::V1::ApplicationController
	before_action :authorize_request, except: [:login, :register, :forgot_password, :social_login]

	def register
		begin
			user = User.find_by_email(params[:user][:email]) if params[:user][:email].present?
	      raise "Email is already exist" if user.present?
	    user_role = UserRole.find_by(role: params[:user][:role]) if params[:user][:role]
    	raise "Your role is not valid" unless user_role.present?
	    user = User.create!(user_params)
	    user.update(is_admin: true) if params[:user][:role].to_i == 2
	    user.update(user_role_id: user_role.id)
			token = JsonWebToken.encode(user_id: user.id)
			render json: { token: token,
			             user: user }, status: :ok
		rescue Exception => e
      error_handle_bad_request(e)
		end
	end

	def login
		begin
			user = User.find_by_email(params[:user][:email]) if params[:user][:email].present?
	    raise "Please enter valid Email ID" unless user.present?
	    raise "Password is incorrect" unless user.valid_password?(params[:user][:password])
	    if user.present?
		    token = JsonWebToken.encode(user_id: user.id)
				render json: { token: token,user: user }, status: :ok
			else
				render json: { message: 'unauthorized' }, status: :unauthorized
			end
		rescue Exception => e
      error_handle_bad_request(e)
		end
	end

	def social_login
    begin
    	user_role = UserRole.find_by(role: params[:user][:role]) if params[:user][:role]
    	raise "Your role is not valid" unless user_role.present?
      login_with_facebook(params, user_role) if params[:user][:login_with] == "facebook"
      login_with_google(params, user_role) if params[:user][:login_with] == "google"
      @user.update_attributes!(device_id: params[:user][:device_id],device_type: params[:user][:device_type])
     token = JsonWebToken.encode(user_id: @user.id)
      render json: { token: token,
                 user: @user }, status: :ok

    rescue Exception => e
      error_handle_bad_request(e)
    end
  end

  def login_with_facebook(params, user_role)
    fb_info = User.connect_with_facebook(params[:user][:access_token])
    email = fb_info[:email].nil? ? "" : fb_info[:email]
     user = User.find_by(email: fb_info[:email]).present? if fb_info[:email].present?
    if user.present?
      @user = user
      raise  "Your role is not valid" if user_role.to_i != @user.user_role_id.to_i
    elsif User.find_by(social_id: fb_info[:id],login_with: params[:user][:login_with]).present?
      @user = User.find_by(social_id: fb_info[:id],login_with: params[:user][:login_with])
      raise  "Your role is not valid" if params[:user][:role].to_i != @user.role.to_i
    elsif fb_info[:error].blank?
      fb_id = fb_info[:id]
      first_name = fb_info[:first_name].nil? ? "" : fb_info[:first_name]
      last_name = fb_info[:last_name].nil? ? "" : fb_info[:last_name]
      full_name = first_name + " " + last_name
      password = Devise.friendly_token
        @user = User.new(:name=>full_name, :social_id=>fb_id,:email=>email,:password=>password,user_role_id: user_role.id,login_with: "facebook"
          )

      image_url = "https://graph.facebook.com/#{fb_info[:id]}/picture?type=large"
      avatar_url =image_url.gsub("­http","htt­ps")
      avatar_url_new = @user.process_uri(avatar_url)
      @user.remote_image_url = avatar_url_new
      @user.save

    else
      raise "access token is invalid"
    end
  end

  def login_with_google(params, user_role)
    begin
			google_info = User.connect_with_google(params[:user][:access_token])
      raise "Access token is invalid" if google_info[:error].present?
      email = google_info[:email].nil? ?  "" : google_info[:email]
      user = User.find_by(email: google_info[:email]).present? if google_info[:email].present?
      if user.present?
        @user = user
      elsif User.find_by(social_id: google_info[:id],login_with: params[:user][:login_with]).present?
        @user = User.find_by(social_id: google_info[:id],login_with: params[:user][:login_with])
        raise  "Your role is not valid" if user_role != @user.user_role_idss
      elsif google_info[:error].blank?
        google_id = google_info[:id]
        first_name = google_info[:first_name].nil? ? "" : google_info[:first_name]
        last_name = google_info[:last_name].nil? ? "" : google_info[:last_name]
        full_name = first_name + " " + last_name
         password = Devise.friendly_token
          @user = User.new(:name=>full_name, :social_id=>google_id,:email=>email,:password=>password,user_role_id: user_role.id,login_with: "google")
        avatar_url_new = @user.process_uri(google_info[:picture])
        @user.remote_image_url = avatar_url_new
        @user.save
      else
        raise "access token  is invalid"
      end
    end
  end

	def forgot_password
	  	begin
				raise "Enter your email" unless params[:user][:email].present?
				user = User.find_by_email(params[:user][:email])
				raise "User not found" unless user.present?
				user.send_reset_password_instructions

				mailer={}

				mailer[:token] = user.reset_password_token
	      mailer[:user] = user
        mailer[:url] = request.base_url
        UserMailer.forgot_password_on_mail(mailer).deliver_now
				render :json => {message: "Email has been sent successfully"}
		rescue Exception => e
			error_handle_bad_request(e)
		end
	end

	def change_password
		begin
			raise "Please enter old password" unless params[:user][:old_password].present?
			raise "Please enter old new password" unless params[:user][:new_password].present?
			raise "old password is incorrect" unless @current_api_user.valid_password?(params[:user][:old_password])
			@current_api_user.update(password: params[:user][:new_password])
			render :json => {message: "Password has been changed successfully"}
		rescue Exception => e
				error_handle_bad_request(e)
			end
	end

	def profile
	 @current_api_user.update(profile_params)
	 render :user
	end

	def get_image
		render :json => {image: @current_api_user.try(:image)}
	end

	def update_image
		begin
		raise "Please choose Image File" unless params[:image].present?
		id =  ENV['AWS_ACCESS_KEY_ID']
		secret_key = ENV['AWS_SECRET_ACCESS_KEY']
		bucket_name = ENV['S3_BUCKET_NAME']
		s3 = Aws::S3::Resource.new(credentials: Aws::Credentials.new(id, secret_key),
	  region: 'us-east-1')
		if @current_api_user.try(:image).present?
			image_url = @current_api_user.image.split("com/")[1]
			obj = s3.bucket(bucket_name).object(image_url)
			obj.delete
		end
		image_name = params[:image].original_filename
		obj = s3.bucket(bucket_name).object("users/images/#{@current_api_user.id}/#{image_name}")

		obj.upload_file(params[:image].path)
		@current_api_user.update(image: obj.public_url)

		render :user
		rescue Exception => e
			error_handle_bad_request(e)
		end
	end


	def get_user_profile
		@user = @current_api_user
		render :user
	end

	def user_by_id
		begin
			return "User id is not present" unless params[:id].present?
			user = User.find_by(id: params[:id])
			return "Please enter a valid Id" unless user.present?
			@user = user
			render :user
		rescue Exception => e		
			error_handle_bad_request(e)	
		end
	end

	def update_user_by_id
		begin
			return "User id is not present" unless params[:id].present?
			user = User.find_by(id: params[:id])
			return "Please enter a valid Id" unless user.present?
			user_role = UserRole.find_by(role: params[:user][:role]) if params[:user][:role]
    	raise "Your role is not valid" unless user_role.present?
    	user.update(user_role_id: user_role.id)
			user.update(profile_params)
			@user = user
			render :user
		rescue Exception => e		
			error_handle_bad_request(e)	
		end
	end

	def delete_user
		begin
			return "User id is not present" unless params[:id].present?
			user = User.find_by(id: params[:id])
			return "Please enter a valid Id" unless user.present?
			user.destroy
			render json: {message: "Destroyed successfully"}, status: :ok
		rescue Exception => e
			error_handle_bad_request(e)
		end
	end


	def get_all_users
		begin
			raise "Access denied" unless @current_api_user.is_admin
			@users = User.all.where(is_admin: false)
			render :users
		rescue Exception => e
			error_handle_bad_request(e)
		end
	end

	def logout
		begin
			token = JsonWebToken.encode(user_id: @current_api_user.id, exp: Time.now.to_i)
			render json: { token: token , message: "logout successfully"}, status: :ok
		rescue Exception => e
			error_handle_bad_request(e)
		end
	end

	private

	def user_params
		params.require(:user).permit(:email, :password, :name)
	end

	def profile_params
		params.require(:user).permit(:email, :name)
	end
end
